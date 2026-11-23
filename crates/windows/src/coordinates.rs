pub(super) fn hit_coordinate(value: f64) -> Option<i32> {
    checked_coordinate(value).map(|value| value.floor() as i32)
}

pub(super) fn frame_coordinate(value: f64) -> Option<i32> {
    checked_coordinate(value).map(|value| value.round() as i32)
}

fn checked_coordinate(value: f64) -> Option<f64> {
    (f64::from(i32::MIN)..=f64::from(i32::MAX))
        .contains(&value)
        .then_some(value)
}

#[cfg(test)]
mod tests {
    use super::{frame_coordinate, hit_coordinate};

    #[test]
    fn fractional_hit_coordinates_stay_in_the_same_pixel() {
        for edge in [-300, 0, 300] {
            assert_eq!(hit_coordinate(f64::from(edge) - 0.25), Some(edge - 1));
            assert_eq!(hit_coordinate(f64::from(edge)), Some(edge));
            assert_eq!(hit_coordinate(f64::from(edge) + 0.25), Some(edge));
        }
    }

    #[test]
    fn native_frame_coordinates_still_round_to_the_nearest_pixel() {
        for (value, expected) in [(-1.75, -2), (-0.25, 0), (0.25, 0), (1.75, 2)] {
            assert_eq!(frame_coordinate(value), Some(expected));
        }
    }

    #[test]
    fn native_coordinate_conversions_reject_invalid_values() {
        for convert in [hit_coordinate, frame_coordinate] {
            for edge in [i32::MIN, i32::MAX] {
                assert_eq!(convert(f64::from(edge)), Some(edge));
            }
            for value in [
                f64::NAN,
                f64::NEG_INFINITY,
                f64::INFINITY,
                f64::from(i32::MIN) - 0.25,
                f64::from(i32::MAX) + 0.25,
            ] {
                assert_eq!(convert(value), None);
            }
        }
    }
}
