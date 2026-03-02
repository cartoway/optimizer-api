//! Delaunay triangulation using spade crate.
//! Builds a triangulation from (lon, lat) points and returns undirected edges as (index_a, index_b) pairs.

use spade::{DelaunayTriangulation, HasPosition, Point2, Triangulation};

/// Vertex with index for mapping back to service order
#[derive(Clone, Copy)]
struct IndexedPoint {
    point: Point2<f64>,
    index: usize,
}

impl HasPosition for IndexedPoint {
    type Scalar = f64;

    fn position(&self) -> Point2<Self::Scalar> {
        self.point
    }
}

/// Builds Delaunay triangulation from points and returns edges as (i, j) index pairs.
///
/// # Arguments
/// * `points` - Slice of (lon, lat) coordinates. Index in array = service index.
///
/// # Returns
/// Vector of (index_a, index_b) for each undirected edge, with index_a < index_b to avoid duplicates.
pub fn compute_edges(points: &[(f64, f64)]) -> Result<Vec<(usize, usize)>, spade::InsertionError> {
    let mut triangulation: DelaunayTriangulation<IndexedPoint> = DelaunayTriangulation::new();

    for (index, &(lon, lat)) in points.iter().enumerate() {
        triangulation.insert(IndexedPoint {
            point: Point2::new(lon, lat),
            index,
        })?;
    }

    let mut edges = std::collections::HashSet::new();
    for face in triangulation.inner_faces() {
        let vertices = face.vertices();
        let indices: Vec<usize> = vertices.iter().map(|v| v.data().index).collect();
        for i in 0..3 {
            let a = indices[i];
            let b = indices[(i + 1) % 3];
            let (lo, hi) = if a < b { (a, b) } else { (b, a) };
            edges.insert((lo, hi));
        }
    }

    Ok(edges.into_iter().collect())
}
