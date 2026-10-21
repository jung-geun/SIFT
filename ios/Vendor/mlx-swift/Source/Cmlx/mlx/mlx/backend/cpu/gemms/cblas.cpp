// Copyright © 2025 Apple Inc.
// SIFT: retain wide batch offsets and check BLAS integer boundaries once.

#include "mlx/backend/common/utils.h"
#include "mlx/backend/cpu/gemm.h"
#include "mlx/backend/cpu/lapack.h"
#include "mlx/sift_checked_cast.h"

namespace mlx::core {

template <>
void matmul<float>(
    const float* a,
    const float* b,
    float* out,
    bool a_transposed,
    bool b_transposed,
    size_t lda,
    size_t ldb,
    size_t ldc,
    float alpha,
    float beta,
    size_t batch_size,
    const Shape& a_shape,
    const Strides& a_strides,
    const Shape& b_shape,
    const Strides& b_strides) {
  auto ndim = a_shape.size();
  int M = a_shape[ndim - 2];
  int N = b_shape[ndim - 1];
  int K = a_shape[ndim - 1];
  const auto blas_lda = sift_checked_cast<int>(lda);
  const auto blas_ldb = sift_checked_cast<int>(ldb);
  const auto blas_ldc = sift_checked_cast<int>(ldc);
  const auto batches = sift_checked_cast<int64_t>(batch_size);
  const int64_t a_matrix_size = int64_t{M} * K;
  const int64_t b_matrix_size = int64_t{K} * N;
  const int64_t out_matrix_size = int64_t{M} * N;

  for (int64_t i = 0; i < batches; ++i) {
    cblas_sgemm(
        CblasRowMajor,
        a_transposed ? CblasTrans : CblasNoTrans, // transA
        b_transposed ? CblasTrans : CblasNoTrans, // transB
        M,
        N,
        K,
        alpha,
        a + elem_to_loc(a_matrix_size * i, a_shape, a_strides),
        blas_lda,
        b + elem_to_loc(b_matrix_size * i, b_shape, b_strides),
        blas_ldb,
        beta,
        out + out_matrix_size * i,
        blas_ldc);
  }
}

template <>
void matmul<double>(
    const double* a,
    const double* b,
    double* out,
    bool a_transposed,
    bool b_transposed,
    size_t lda,
    size_t ldb,
    size_t ldc,
    float alpha,
    float beta,
    size_t batch_size,
    const Shape& a_shape,
    const Strides& a_strides,
    const Shape& b_shape,
    const Strides& b_strides) {
  auto ndim = a_shape.size();
  int M = a_shape[ndim - 2];
  int N = b_shape[ndim - 1];
  int K = a_shape[ndim - 1];
  const auto blas_lda = sift_checked_cast<int>(lda);
  const auto blas_ldb = sift_checked_cast<int>(ldb);
  const auto blas_ldc = sift_checked_cast<int>(ldc);
  const auto batches = sift_checked_cast<int64_t>(batch_size);
  const int64_t a_matrix_size = int64_t{M} * K;
  const int64_t b_matrix_size = int64_t{K} * N;
  const int64_t out_matrix_size = int64_t{M} * N;

  for (int64_t i = 0; i < batches; ++i) {
    cblas_dgemm(
        CblasRowMajor,
        a_transposed ? CblasTrans : CblasNoTrans, // transA
        b_transposed ? CblasTrans : CblasNoTrans, // transB
        M,
        N,
        K,
        alpha,
        a + elem_to_loc(a_matrix_size * i, a_shape, a_strides),
        blas_lda,
        b + elem_to_loc(b_matrix_size * i, b_shape, b_strides),
        blas_ldb,
        beta,
        out + out_matrix_size * i,
        blas_ldc);
  }
}

template <>
void matmul<complex64_t>(
    const complex64_t* a,
    const complex64_t* b,
    complex64_t* out,
    bool a_transposed,
    bool b_transposed,
    size_t lda,
    size_t ldb,
    size_t ldc,
    float alpha,
    float beta,
    size_t batch_size,
    const Shape& a_shape,
    const Strides& a_strides,
    const Shape& b_shape,
    const Strides& b_strides) {
  auto ndim = a_shape.size();
  int M = a_shape[ndim - 2];
  int N = b_shape[ndim - 1];
  int K = a_shape[ndim - 1];
  const auto blas_lda = sift_checked_cast<int>(lda);
  const auto blas_ldb = sift_checked_cast<int>(ldb);
  const auto blas_ldc = sift_checked_cast<int>(ldc);
  const auto batches = sift_checked_cast<int64_t>(batch_size);
  const int64_t a_matrix_size = int64_t{M} * K;
  const int64_t b_matrix_size = int64_t{K} * N;
  const int64_t out_matrix_size = int64_t{M} * N;
  auto calpha = static_cast<complex64_t>(alpha);
  auto cbeta = static_cast<complex64_t>(beta);

  for (int64_t i = 0; i < batches; ++i) {
    cblas_cgemm(
        CblasRowMajor,
        a_transposed ? CblasTrans : CblasNoTrans, // transA
        b_transposed ? CblasTrans : CblasNoTrans, // transB
        M,
        N,
        K,
        &calpha,
        a + elem_to_loc(a_matrix_size * i, a_shape, a_strides),
        blas_lda,
        b + elem_to_loc(b_matrix_size * i, b_shape, b_strides),
        blas_ldb,
        &cbeta,
        out + out_matrix_size * i,
        blas_ldc);
  }
}

} // namespace mlx::core
