// SIFT modification (2026-10-21): reject host/kernel index truncation.
#pragma once

#include <stdexcept>
#include <type_traits>
#include <utility>

namespace mlx::core {

// Preserve upstream integral values when representable. A kernel/API boundary
// must fail before truncating an oversized dimension, stride, or element count.
// std::in_range is constexpr; widening and same-type checks optimize away.
template <typename To, typename From>
inline To sift_checked_cast(From value) {
  static_assert(std::is_integral_v<To> && std::is_integral_v<From>);
  if (!std::in_range<To>(value)) {
    throw std::overflow_error("MLX integral value exceeds the destination range");
  }
  return static_cast<To>(value);
}

} // namespace mlx::core
