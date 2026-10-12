//! A small command line driver for the library.
//!
//! ```text
//! cargo run --example cli -- scan
//! cargo run --example cli -- version
//! cargo run --example cli -- move left 400 1.0
//! cargo run --example cli -- preset save wide
//! cargo run --example cli -- preset list
//! ```
//!
//! On macOS this must run from a terminal you launched yourself, and the first
//! run prompts for Bluetooth access. A process whose app identity lacks
//! `NSBluetoothAlwaysUsageDescription` is killed outright by TCC — which is
//! exactly what the bundled app fixes.

use std::time::Duration;

use rs3::{Direction, Gimbal, Position, Preset, PresetStore};

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let cmd = args.first().map(String::as_str).unwrap_or("help");

    match cmd {
        "scan" => {
            println!("scanning 8s ...");
            for g in Gimbal::discover(Duration::from_secs(8)).await? {
                let rssi = g.rssi.map(|r| format!("{r:>4} dBm")).unwrap_or_default();
                println!("  {rssi}  {}  {}", g.name, g.id);
            }
        }
        "version" => {
            let g = Gimbal::connect_first().await?;
            println!("{}", g.version().await?);
            g.disconnect().await?;
        }
        "watch" => {
            let g = Gimbal::connect_first().await?;
            println!("listening 10s for status pushes ...");
            tokio::time::sleep(Duration::from_secs(10)).await;
            for f in g.recent_pushes().await.iter().rev().take(10) {
                println!(
                    "  cmdset=0x{:02x} cmdid=0x{:02x} payload={}",
                    f.cmd_set,
                    f.cmd_id,
                    hex(&f.payload)
                );
            }
            g.disconnect().await?;
        }
        "move" => {
            let dir = match args.get(1).map(String::as_str) {
                Some("left") => Direction::Left,
                Some("right") => Direction::Right,
                Some("up") => Direction::Up,
                Some("down") => Direction::Down,
                Some("rollleft") => Direction::RollLeft,
                Some("rollright") => Direction::RollRight,
                other => {
                    eprintln!("unknown direction {other:?}");
                    return Ok(());
                }
            };
            let speed: i16 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(400);
            let secs: f32 = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(1.0);

            let g = Gimbal::connect_first().await?;
            println!("{dir:?} at {speed} for {secs}s");
            g.nudge(dir, speed, Duration::from_secs_f32(secs)).await?;
            g.disconnect().await?;
        }
        "live" => {
            // One connection held open for the whole session, which is how the
            // app works too. Contrast with every other subcommand here, which
            // scans and connects from scratch.
            use std::io::Write;
            use std::sync::Arc;

            let gimbal = Arc::new(Gimbal::connect_first().await?);
            let keepalive = gimbal.spawn_keepalive(Duration::from_millis(500));
            println!("connected: {}", gimbal.version().await?);
            println!("commands: l r u d (hold 0.4s) | s stop | c recenter | v version | q quit");

            let stdin = std::io::stdin();
            loop {
                print!("> ");
                std::io::stdout().flush().ok();
                let mut line = String::new();
                if stdin.read_line(&mut line)? == 0 {
                    break;
                }
                // Each move blocks for ~0.5s, so keystrokes typed during
                // one arrive together on the next read. Treat every character
                // as its own command rather than rejecting "dd" as unknown.
                let hold = Duration::from_millis(400);
                let mut quit = false;
                for ch in line.trim().chars() {
                    match ch {
                        'l' => gimbal.nudge(Direction::Left, 400, hold).await?,
                        'r' => gimbal.nudge(Direction::Right, 400, hold).await?,
                        'u' => gimbal.nudge(Direction::Up, 300, hold).await?,
                        'd' => gimbal.nudge(Direction::Down, 300, hold).await?,
                        's' => gimbal.stop().await?,
                        'c' => gimbal.recenter().await?,
                        'v' => println!("{}", gimbal.version().await?),
                        'q' => {
                            quit = true;
                            break;
                        }
                        other => println!("unknown: {other}"),
                    }
                }
                if quit {
                    break;
                }
                println!(
                    "  link: {}",
                    if keepalive.is_healthy() { "up" } else { "DOWN" }
                );
            }
            drop(keepalive);
            gimbal.disconnect().await?;
        }
        "recenter" => {
            let g = Gimbal::connect_first().await?;
            g.recenter().await?;
            g.disconnect().await?;
        }
        "stop" => {
            let g = Gimbal::connect_first().await?;
            g.stop().await?;
            g.disconnect().await?;
        }
        "preset" => {
            let path = PresetStore::default_path();
            let mut store = PresetStore::load(&path)?;
            match args.get(1).map(String::as_str) {
                Some("list") => {
                    if store.is_empty() {
                        println!("no presets ({})", path.display());
                    }
                    for p in store.iter() {
                        let (y, r, pi) = p.position.degrees();
                        println!("  {:<16} yaw={y:>7.1} roll={r:>7.1} pitch={pi:>7.1}", p.name);
                    }
                }
                Some("save") => {
                    let name = args.get(2).cloned().unwrap_or_else(|| "preset".into());
                    // The gimbal does not answer attitude queries, so a preset
                    // records the position you supply rather than the live one.
                    let nums: Vec<f32> = args[3..].iter().filter_map(|s| s.parse().ok()).collect();
                    let pos = match nums.as_slice() {
                        [y, r, p] => Position::from_degrees(*y, *r, *p),
                        _ => Position::default(),
                    };
                    store.add(Preset::new(&name, pos));
                    store.save(&path)?;
                    println!("saved {name} -> {:?}", pos.degrees());
                }
                Some("remove") => {
                    let name = args.get(2).cloned().unwrap_or_default();
                    match store.remove(&name) {
                        Some(_) => {
                            store.save(&path)?;
                            println!("removed {name}");
                        }
                        None => println!("no preset named {name}"),
                    }
                }
                Some("goto") => {
                    let name = args.get(2).cloned().unwrap_or_default();
                    let Some(p) = store.get(&name) else {
                        println!("no preset named {name}");
                        return Ok(());
                    };
                    let g = Gimbal::connect_first().await?;
                    g.goto(p.position).await?;
                    g.disconnect().await?;
                }
                _ => println!("preset list|save <name> [yaw roll pitch]|remove <name>|goto <name>"),
            }
        }
        "raw" => {
            let parse = |s: &String| u8::from_str_radix(s.trim_start_matches("0x"), 16).ok();
            let (Some(cs), Some(ci)) = (args.get(1).and_then(parse), args.get(2).and_then(parse))
            else {
                println!("raw <cmdset> <cmdid> [hex payload]");
                return Ok(());
            };
            let payload = args
                .get(3)
                .map(|h| {
                    (0..h.len())
                        .step_by(2)
                        .filter_map(|i| u8::from_str_radix(&h[i..i + 2], 16).ok())
                        .collect()
                })
                .unwrap_or_default();
            let g = Gimbal::connect_first().await?;
            g.raw(cs, ci, payload).await?;
            g.disconnect().await?;
        }
        _ => {
            println!("rs3 — control a DJI RS gimbal over Bluetooth LE\n");
            println!("  live                       hold one connection, interactive");
            println!("  scan                       list nearby gimbals");
            println!("  version                    hardware id and firmware");
            println!("  watch                      show status pushes for 10s");
            println!("  move <dir> [speed] [secs]  left|right|up|down|rollleft|rollright");
            println!("  recenter                   recentre the gimbal");
            println!("  stop                       zero all axes");
            println!("  preset list|save|remove|goto");
            println!("  raw <cmdset> <cmdid> [hex] send any recovered command");
        }
    }
    Ok(())
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}
