//! Standalone CLI: reads JSON points from stdin, outputs JSON edges to stdout.
//! Input: [[lon, lat], [lon, lat], ...]
//! Output: [[i, j], [i, j], ...]

mod delaunay;

use std::io::{self, Read};
use std::process::exit;

fn main() {
    let mut input = String::new();
    if io::stdin().read_to_string(&mut input).is_err() {
        eprintln!("Failed to read stdin");
        exit(1);
    }

    let points: Vec<Vec<f64>> = match serde_json::from_str(&input) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("Invalid JSON: {}", e);
            exit(1);
        }
    };

    let coords: Vec<(f64, f64)> = points
        .iter()
        .map(|p| {
            if p.len() < 2 {
                (0.0, 0.0)
            } else {
                (p[0], p[1])
            }
        })
        .collect();

    match delaunay::compute_edges(&coords) {
        Ok(edges) => {
            if let Err(e) = serde_json::to_writer(io::stdout(), &edges) {
                eprintln!("Output error: {}", e);
                exit(1);
            }
        }
        Err(e) => {
            eprintln!("Delaunay error: {}", e);
            exit(1);
        }
    }
}
