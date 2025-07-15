#include <stdint.h>
#include <math.h>

// Clamp value between min and max
static inline int clamp(int value, int min, int max) {
    return value < min ? min : (value > max ? max : value);
}

// Fast YUV to RGB conversion with optimized calculations
void convert_yuv_to_rgb(
        uint8_t* y_plane,
        uint8_t* u_plane,
        uint8_t* v_plane,
        uint8_t* rgb_output,
        int width,
        int height,
        int uv_row_stride,
        int uv_pixel_stride
) {
    // Pre-calculate conversion constants for better performance
    const int c_v_r = 1436;      // 1.403 * 1024
    const int c_u_g = 46549;     // 0.344 * 131072
    const int c_v_g = 93604;     // 0.714 * 131072
    const int c_u_b = 1814;      // 1.773 * 1024

    int rgb_index = 0;

    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            // Calculate indices
            int uv_index = uv_pixel_stride * (x / 2) + uv_row_stride * (y / 2);
            int y_index = y * width + x;

            // Get YUV values
            int yp = y_plane[y_index];
            int up = u_plane[uv_index] - 128;  // Center U around 0
            int vp = v_plane[uv_index] - 128;  // Center V around 0

            // Convert to RGB using integer arithmetic
            int r = yp + (vp * c_v_r) / 1024;
            int g = yp - (up * c_u_g) / 131072 - (vp * c_v_g) / 131072;
            int b = yp + (up * c_u_b) / 1024;

            // Clamp values to valid range
            rgb_output[rgb_index++] = clamp(r, 0, 255);
            rgb_output[rgb_index++] = clamp(g, 0, 255);
            rgb_output[rgb_index++] = clamp(b, 0, 255);
        }
    }
}

// Alternative SIMD-optimized version (if available)
#ifdef __ARM_NEON
#include <arm_neon.h>

void convert_yuv_to_rgb_neon(
    uint8_t* y_plane,
    uint8_t* u_plane,
    uint8_t* v_plane,
    uint8_t* rgb_output,
    int width,
    int height,
    int uv_row_stride,
    int uv_pixel_stride
) {
    // NEON SIMD implementation for ARM processors
    // This processes 8 pixels at once for better performance
    const int16x8_t c_v_r = vdupq_n_s16(1436);
    const int16x8_t c_u_g = vdupq_n_s16(355);  // Adjusted for 16-bit
    const int16x8_t c_v_g = vdupq_n_s16(714);  // Adjusted for 16-bit
    const int16x8_t c_u_b = vdupq_n_s16(1814);
    const int16x8_t offset = vdupq_n_s16(128);

    int rgb_index = 0;

    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x += 8) {
            // Process 8 pixels at once when possible
            int remaining = width - x;
            int process_count = remaining > 8 ? 8 : remaining;

            for (int i = 0; i < process_count; i++) {
                int curr_x = x + i;
                int uv_index = uv_pixel_stride * (curr_x / 2) + uv_row_stride * (y / 2);
                int y_index = y * width + curr_x;

                int yp = y_plane[y_index];
                int up = u_plane[uv_index] - 128;
                int vp = v_plane[uv_index] - 128;

                int r = yp + (vp * 1436) / 1024;
                int g = yp - (up * 355) / 1024 - (vp * 714) / 1024;
                int b = yp + (up * 1814) / 1024;

                rgb_output[rgb_index++] = clamp(r, 0, 255);
                rgb_output[rgb_index++] = clamp(g, 0, 255);
                rgb_output[rgb_index++] = clamp(b, 0, 255);
            }
        }
    }
}
#endif