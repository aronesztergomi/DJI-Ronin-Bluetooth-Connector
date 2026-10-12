//! Bluetooth LE transport.
//!
//! The gimbal exposes vendor service `fff0` with three characteristics:
//!
//! | | |
//! |---|---|
//! | `fff5` | write, write-without-response — commands out |
//! | `fff4` | notify — replies and status pushes |
//! | `fff3` | advertises notify but has **no CCCD**, so it cannot be subscribed |
//!
//! Only `fff4` carries inbound traffic, so `fff3` is skipped deliberately.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use btleplug::api::{
    Central, CentralEvent, Characteristic, Manager as _, Peripheral as _, ScanFilter, WriteType,
};
use btleplug::platform::{Adapter, Manager, Peripheral};
use futures::StreamExt;
use tokio::sync::{oneshot, Mutex};
use uuid::Uuid;

use crate::protocol::{cmd_id, cmd_set, split_frames, Frame};
use crate::{
    Direction, Error, Position, Result, Speeds, Version, CONTROL_RATE, CTRL_BYTE, RECENTER_BODY,
};

pub const SERVICE_FFF0: Uuid = Uuid::from_u128(0x0000fff0_0000_1000_8000_00805f9b34fb);
pub const CHAR_WRITE: Uuid = Uuid::from_u128(0x0000fff5_0000_1000_8000_00805f9b34fb);
pub const CHAR_NOTIFY: Uuid = Uuid::from_u128(0x0000fff4_0000_1000_8000_00805f9b34fb);

/// A gimbal seen while scanning.
#[derive(Debug, Clone)]
pub struct DiscoveredGimbal {
    pub id: String,
    pub name: String,
    pub rssi: Option<i16>,
    peripheral: Peripheral,
}

impl DiscoveredGimbal {
    pub async fn connect(self) -> Result<Gimbal> {
        Gimbal::open(self.peripheral).await
    }
}

/// A connected gimbal.
pub struct Gimbal {
    peripheral: Peripheral,
    /// Kept so a dropped link can be re-established without rescanning blind.
    id: String,
    /// The BLE advertised name, e.g. "DJI RS3-081GWN".
    name: String,
    write: Characteristic,
    seq: Mutex<u16>,
    waiters: Arc<Mutex<HashMap<u16, oneshot::Sender<Frame>>>>,
    pushes: Arc<Mutex<Vec<Frame>>>,
}

impl Gimbal {
    /// Scan for RS-series gimbals.
    pub async fn discover(timeout: Duration) -> Result<Vec<DiscoveredGimbal>> {
        let adapter = default_adapter().await?;
        adapter.start_scan(ScanFilter::default()).await?;

        // Drain scan events for the window rather than sleeping blindly, so a
        // gimbal that shows up early is still reported promptly.
        let mut events = adapter.events().await?;
        let deadline = tokio::time::Instant::now() + timeout;
        loop {
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            if remaining.is_zero() {
                break;
            }
            match tokio::time::timeout(remaining, events.next()).await {
                Ok(Some(CentralEvent::DeviceDiscovered(_))) => {}
                Ok(Some(_)) => {}
                Ok(None) | Err(_) => break,
            }
        }
        let _ = adapter.stop_scan().await;

        let mut found = Vec::new();
        for p in adapter.peripherals().await? {
            let Some(props) = p.properties().await? else {
                continue;
            };
            let name = props.local_name.unwrap_or_default();
            let advertises_fff0 = props.services.contains(&SERVICE_FFF0);
            let looks_like_rs = {
                let n = name.to_lowercase();
                n.contains("rs") && n.contains("dji")
            };
            if advertises_fff0 || looks_like_rs {
                found.push(DiscoveredGimbal {
                    id: p.id().to_string(),
                    name: if name.is_empty() { "(unnamed)".into() } else { name },
                    rssi: props.rssi,
                    peripheral: p,
                });
            }
        }
        Ok(found)
    }

    /// Scan briefly and connect to the first gimbal found.
    pub async fn connect_first() -> Result<Self> {
        let found = Self::discover(Duration::from_secs(8)).await?;
        let first = found.into_iter().next().ok_or(Error::NotFound)?;
        first.connect().await
    }

    async fn open(peripheral: Peripheral) -> Result<Self> {
        let name = peripheral
            .properties()
            .await
            .ok()
            .flatten()
            .and_then(|p| p.local_name)
            .unwrap_or_else(|| "DJI RS gimbal".to_string());
        if !peripheral.is_connected().await? {
            peripheral.connect().await?;
        }
        peripheral.discover_services().await?;

        let chars = peripheral.characteristics();
        let write = chars
            .iter()
            .find(|c| c.uuid == CHAR_WRITE)
            .cloned()
            .ok_or(Error::NotAGimbal)?;
        let notify = chars
            .iter()
            .find(|c| c.uuid == CHAR_NOTIFY)
            .cloned()
            .ok_or(Error::NotAGimbal)?;
        peripheral.subscribe(&notify).await?;

        let waiters: Arc<Mutex<HashMap<u16, oneshot::Sender<Frame>>>> = Default::default();
        let pushes: Arc<Mutex<Vec<Frame>>> = Default::default();

        // Fan incoming notifications out to whoever is waiting on that seq.
        {
            let mut stream = peripheral.notifications().await?;
            let waiters = waiters.clone();
            let pushes = pushes.clone();
            tokio::spawn(async move {
                while let Some(n) = stream.next().await {
                    for frame in split_frames(&n.value).into_iter().flatten() {
                        if frame.is_reply() {
                            if let Some(tx) = waiters.lock().await.remove(&frame.seq) {
                                let _ = tx.send(frame);
                                continue;
                            }
                        }
                        let mut p = pushes.lock().await;
                        p.push(frame);
                        let overflow = p.len().saturating_sub(200);
                        p.drain(..overflow);
                    }
                }
            });
        }

        Ok(Self {
            id: peripheral.id().to_string(),
            name,
            peripheral,
            write,
            seq: Mutex::new(0x1000),
            waiters,
            pushes,
        })
    }

    pub async fn disconnect(&self) -> Result<()> {
        // Stopping first is a courtesy, and the same hang applies: if the
        // device is already gone this write can block forever and wedge
        // whatever thread called us.
        let _ = tokio::time::timeout(Duration::from_millis(300), self.stop()).await;
        self.peripheral.disconnect().await?;
        Ok(())
    }

    /// The platform identifier this gimbal was found under.
    pub fn id(&self) -> &str {
        &self.id
    }

    /// The name the gimbal advertises, e.g. "DJI RS3-081GWN".
    pub fn name(&self) -> &str {
        &self.name
    }

    /// Re-establish a dropped link to the same device.
    ///
    /// Returns a fresh [`Gimbal`] because the notification stream and its
    /// pending waiters belong to the old connection and cannot be reused.
    pub async fn reconnect(&self) -> Result<Self> {
        if self.peripheral.is_connected().await.unwrap_or(false) {
            let _ = self.peripheral.disconnect().await;
        }
        Self::open(self.peripheral.clone()).await
    }

    pub async fn is_connected(&self) -> bool {
        self.peripheral.is_connected().await.unwrap_or(false)
    }

    /// Status frames the gimbal has pushed at us, newest last.
    pub async fn recent_pushes(&self) -> Vec<Frame> {
        self.pushes.lock().await.clone()
    }

    // ------------------------------------------------------------- plumbing

    async fn next_seq(&self) -> u16 {
        let mut s = self.seq.lock().await;
        *s = s.wrapping_add(1);
        *s
    }

    async fn send(&self, cmd_set: u8, cmd_id: u8, payload: Vec<u8>) -> Result<()> {
        let seq = self.next_seq().await;
        let frame = Frame::command(cmd_set, cmd_id, payload, seq, false).encode()?;
        self.peripheral
            .write(&self.write, &frame, WriteType::WithoutResponse)
            .await?;
        Ok(())
    }

    async fn request(&self, cmd_set: u8, cmd_id: u8, payload: Vec<u8>, timeout: Duration) -> Result<Frame> {
        let seq = self.next_seq().await;
        let (tx, rx) = oneshot::channel();
        self.waiters.lock().await.insert(seq, tx);

        let frame = Frame::command(cmd_set, cmd_id, payload, seq, true).encode()?;
        self.peripheral
            .write(&self.write, &frame, WriteType::WithoutResponse)
            .await?;

        match tokio::time::timeout(timeout, rx).await {
            Ok(Ok(f)) => Ok(f),
            _ => {
                self.waiters.lock().await.remove(&seq);
                Err(Error::Timeout)
            }
        }
    }

    // -------------------------------------------------------------- queries

    /// The only query this firmware answers.
    pub async fn version(&self) -> Result<Version> {
        let reply = self
            .request(
                cmd_set::COMMON,
                cmd_id::COMMON_GET_VERSION,
                Vec::new(),
                Duration::from_secs(2),
            )
            .await?;
        Version::parse(&reply.payload)
    }

    // -------------------------------------------------------------- control

    /// One speed command. Send repeatedly to sustain motion.
    pub async fn speed(&self, speeds: Speeds) -> Result<()> {
        self.send(
            cmd_set::GIMBAL,
            cmd_id::GIMBAL_CONTROL_SPEED,
            speeds.to_payload(CTRL_BYTE),
        )
        .await
    }

    /// Zero every axis.
    pub async fn stop(&self) -> Result<()> {
        for _ in 0..3 {
            self.speed(Speeds::STOP).await?;
            tokio::time::sleep(Duration::from_millis(40)).await;
        }
        Ok(())
    }

    /// Hold a direction for a while, then stop.
    pub async fn nudge(&self, dir: Direction, speed: i16, duration: Duration) -> Result<()> {
        let speeds = dir.to_speeds(speed);
        let ticks = (duration.as_millis() / CONTROL_RATE.as_millis()).max(1);
        for _ in 0..ticks {
            self.speed(speeds).await?;
            tokio::time::sleep(CONTROL_RATE).await;
        }
        self.stop().await
    }

    /// Move toward an absolute attitude.
    ///
    /// Unlike [`Gimbal::speed`], this path is **not yet confirmed on hardware**:
    /// the 9-byte body length comes from the binary but its field layout is
    /// inferred. Verify before relying on it.
    pub async fn goto(&self, pos: Position) -> Result<()> {
        self.send(
            cmd_set::GIMBAL,
            cmd_id::GIMBAL_CONTROL_ANGLE,
            pos.to_payload(0x01, 20),
        )
        .await
    }

    /// Recentre the gimbal (`ResetAndSetMode`).
    ///
    /// The body is two bytes, `0xFE` then `0x01` — not one. A one-byte body
    /// is the wrong length for this command and the gimbal ignores it.
    pub async fn recenter(&self) -> Result<()> {
        self.send(
            cmd_set::GIMBAL,
            cmd_id::GIMBAL_RESET_AND_SET_MODE,
            RECENTER_BODY.to_vec(),
        )
        .await
    }

    /// Keep the session warm and notice if it drops.
    ///
    /// The DJI app sends a heartbeat every 500 ms, which suggests the gimbal
    /// expects traffic. We have observed the link stay up for ~30 s with
    /// nothing sent, so this may be unnecessary — it is opt-in rather than
    /// automatic, and cheap either way.
    ///
    /// The probe is a zero-speed command: harmless, and it exercises the same
    /// write path real control uses, so a dead link is noticed promptly.
    /// Dropping the returned [`KeepAlive`] stops the task.
    pub fn spawn_keepalive(self: &Arc<Self>, interval: Duration) -> KeepAlive {
        let (stop_tx, mut stop_rx) = tokio::sync::oneshot::channel::<()>();
        let gimbal = Arc::clone(self);
        let alive = Arc::new(std::sync::atomic::AtomicBool::new(true));
        let flag = Arc::clone(&alive);

        tokio::spawn(async move {
            let mut ticker = tokio::time::interval(interval);
            ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            loop {
                tokio::select! {
                    _ = &mut stop_rx => break,
                    _ = ticker.tick() => {
                        // A write to a peripheral that has gone away can hang
                        // rather than fail — CoreBluetooth has nothing to time
                        // out against — which parks this task forever, still
                        // reporting the last good result. That is how a gimbal
                        // that had been switched off went on showing as
                        // connected. Bound the probe so a hang reads as dead.
                        let probe = async {
                            gimbal.is_connected().await
                                && gimbal.speed(Speeds::STOP).await.is_ok()
                        };
                        let ok = tokio::time::timeout(interval, probe)
                            .await
                            .unwrap_or(false);
                        flag.store(ok, std::sync::atomic::Ordering::Relaxed);
                        if !ok {
                            tracing::warn!("gimbal link lost");
                        }
                    }
                }
            }
        });

        KeepAlive { _stop: stop_tx, alive }
    }

    /// Escape hatch for any of the recovered commands not wrapped above.
    pub async fn raw(&self, cmd_set: u8, cmd_id: u8, payload: Vec<u8>) -> Result<()> {
        self.send(cmd_set, cmd_id, payload).await
    }
}

/// Handle for a running keep-alive task. Drop it to stop.
pub struct KeepAlive {
    _stop: tokio::sync::oneshot::Sender<()>,
    alive: Arc<std::sync::atomic::AtomicBool>,
}

impl KeepAlive {
    /// Whether the most recent probe succeeded.
    pub fn is_healthy(&self) -> bool {
        self.alive.load(std::sync::atomic::Ordering::Relaxed)
    }
}

async fn default_adapter() -> Result<Adapter> {
    let manager = Manager::new().await?;
    manager
        .adapters()
        .await?
        .into_iter()
        .next()
        .ok_or(Error::NoAdapter)
}
