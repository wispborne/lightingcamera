#include <stdint.h>
#include <math.h>


static inline int clamp(int value, int min, int max) {
    return value < min ? min : (value > max ? max : value);
}

/**
 * Converts YUV planar data to RGB with optional rotation.
 * @param y_plane        Pointer to Y plane.
 * @param u_plane        Pointer to U plane.
 * @param v_plane        Pointer to V plane.
 * @param rgb_output     Pointer to RGB output buffer (size: width * height * 3).
 * @param width          Source image width.
 * @param height         Source image height.
 * @param uv_row_stride  Row stride for U/V planes.
 * @param uv_pixel_stride Pixel stride for U/V planes.
 * @param rotation       Rotation in degrees (0, 90, 180, 270).
 */
void convert_yuv_to_rgb(
        uint8_t *y_plane,
        uint8_t *u_plane,
        uint8_t *v_plane,
        uint8_t *rgb_output,
        int width,
        int height,
        int uv_row_stride,
        int uv_pixel_stride,
        int rotation
) {
    // Pre-calculate conversion constants for better performance
    const int c_v_r = 1436;      // 1.402 * 1024
    const int c_u_g = 45100;     // 0.34414 * 131072 (Corrected)
    const int c_v_g = 93604;     // 0.71414 * 131072
    const int c_u_b = 1814;      // 1.772 * 1024

    const int dest_width = (rotation == 90 || rotation == 270) ? height : width;

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

            int dest_x, dest_y;
            switch (rotation) {
                case 90:
                    dest_x = height - 1 - y;
                    dest_y = x;
                    break;
                case 180:
                    dest_x = width - 1 - x;
                    dest_y = height - 1 - y;
                    break;
                case 270:
                    dest_x = y;
                    dest_y = width - 1 - x;
                    break;
                default:
                    dest_x = x;
                    dest_y = y;
                    break;
            }

            int dest_index = (dest_y * dest_width + dest_x) * 3;
            rgb_output[dest_index] = clamp(r, 0, 255);
            rgb_output[dest_index + 1] = clamp(g, 0, 255);
            rgb_output[dest_index + 2] = clamp(b, 0, 255);
        }
    }
}