//! Exact comparisons for normalized rectangles; placement output remains floating point.
use crate::Rect;
use num_bigint::{BigInt, Sign};

// Every finite f64 is an integer multiple of 2^-1074. Keeping that common unit
// preserves all coordinate differences, including subnormals and opposite signs.
fn coordinate(value: f64) -> BigInt {
    debug_assert!(value.is_finite());
    let bits = value.to_bits();
    let exponent = ((bits >> 52) & 0x7ff) as usize;
    let fraction = bits & ((1_u64 << 52) - 1);
    let mantissa = fraction | if exponent == 0 { 0 } else { 1_u64 << 52 };
    let magnitude = BigInt::from(mantissa) << exponent.saturating_sub(1);
    if bits >> 63 == 0 {
        magnitude
    } else {
        -magnitude
    }
}

pub(crate) struct ExactRect {
    x: BigInt,
    y: BigInt,
    max_x: BigInt,
    max_y: BigInt,
}

impl ExactRect {
    pub(crate) fn new(rect: Rect) -> Self {
        let rect = rect.normalized();
        let x = coordinate(rect.x);
        let y = coordinate(rect.y);
        Self {
            max_x: &x + coordinate(rect.width),
            max_y: &y + coordinate(rect.height),
            x,
            y,
        }
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.x == self.max_x || self.y == self.max_y
    }

    pub(crate) fn contains(&self, x: f64, y: f64) -> bool {
        let x = coordinate(x);
        let y = coordinate(y);
        self.x <= x && x < self.max_x && self.y <= y && y < self.max_y
    }

    pub(crate) fn contains_center(&self, window: &Self) -> bool {
        // Compare doubled endpoints with 2*origin+size, avoiding a rounded half
        // or a midpoint rounded onto a display's excluded maximum edge.
        let x = &window.x + &window.max_x;
        let y = &window.y + &window.max_y;
        (&self.x << 1) <= x
            && x < (&self.max_x << 1)
            && (&self.y << 1) <= y
            && y < (&self.max_y << 1)
    }

    pub(crate) fn overlap_area(&self, other: &Self) -> Option<BigInt> {
        let width = (&self.max_x).min(&other.max_x) - (&self.x).max(&other.x);
        if width.sign() != Sign::Plus {
            return None;
        }
        let height = (&self.max_y).min(&other.max_y) - (&self.y).max(&other.y);
        if height.sign() != Sign::Plus {
            return None;
        }
        Some(width * height)
    }
}
