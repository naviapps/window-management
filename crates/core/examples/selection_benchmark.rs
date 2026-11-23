//! Run with --release; reports local measurements rather than enforcing a CI timing assertion.
use std::{hint::black_box, time::Instant};
use window_management::{Display, DisplayQuery, Rect, select_display};

fn main() {
    let displays: Vec<_> = (0..10)
        .map(|i| {
            let frame = Rect {
                x: f64::from(i % 5 - 2) * 1920.0,
                y: f64::from(i / 5) * 1080.0,
                width: 1920.0,
                height: 1080.0,
            };
            Display {
                frame,
                visible_frame: frame,
                identifier: i as u64,
                has_identifier: 1,
                is_main: u32::from(i == 2),
            }
        })
        .collect();
    let windows: Vec<_> = displays
        .iter()
        .map(|display| {
            DisplayQuery::ContainingWindow(Rect {
                x: display.frame.x + 1650.25,
                y: display.frame.y + 480.5,
                width: 850.5,
                height: 720.25,
            })
        })
        .collect();
    const ITERATIONS: usize = 20_000;
    const BUDGET_US: f64 = 100.0;
    for i in 0..2_000 {
        black_box(select_display(black_box(&displays), windows[i % 10], false));
    }
    let mut samples = Vec::new();
    for _ in 0..7 {
        let start = Instant::now();
        for i in 0..ITERATIONS {
            black_box(select_display(
                black_box(&displays),
                black_box(windows[i % 10]),
                false,
            ));
        }
        samples.push(start.elapsed().as_secs_f64() * 1e6 / ITERATIONS as f64);
    }
    samples.sort_by(f64::total_cmp);
    println!("10 displays, 10 spanning window positions, {ITERATIONS} calls/sample, 7 samples");
    println!("microseconds/call: {samples:?}");
    println!(
        "median: {:.3} us; budget: {BUDGET_US:.0} us; within budget: {}",
        samples[3],
        samples[3] <= BUDGET_US
    );
}
