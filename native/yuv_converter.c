#include <stdint.h>
#include <math.h>


static inline int clamp(int value, int min, int max) {
    return value < min ? min : (value > max ? max : value);
}

/**
 * Converts YUV planar data to RGBA with optional integer downscaling and
 * rotation, in a single pass over the output pixels.
 *
 * @param y_plane        Pointer to Y plane.
 * @param u_plane        Pointer to U plane.
 * @param v_plane        Pointer to V plane.
 * @param rgb_output     Pointer to RGBA output buffer
 *                       (size: (width/scale) * (height/scale) * 4).
 * @param width          Source image width.
 * @param height         Source image height.
 * @param y_row_stride   Row stride (bytes per row) of the Y plane. May exceed
 *                       width on devices that pad rows — honoring it avoids
 *                       skewed output.
 * @param uv_row_stride  Row stride for U/V planes.
 * @param uv_pixel_stride Pixel stride for U/V planes.
 * @param rotation       Rotation in degrees (0, 90, 180, 270), already
 *                       normalized by the caller.
 * @param scale          Integer subsample factor (>= 1). 1 keeps full
 *                       resolution; N samples every Nth source pixel for a
 *                       (width/N) x (height/N) result.
 */
void convert_yuv_to_rgb_scaled(
        const uint8_t *y_plane,
        const uint8_t *u_plane,
        const uint8_t *v_plane,
        uint8_t *rgb_output,
        int width,
        int height,
        int y_row_stride,
        int uv_row_stride,
        int uv_pixel_stride,
        int rotation,
        int scale
) {
    // Pre-calculate conversion constants for better performance
    const int c_v_r = 1436;      // 1.402 * 1024
    const int c_u_g = 45100;     // 0.34414 * 131072 (Corrected)
    const int c_v_g = 93604;     // 0.71414 * 131072
    const int c_u_b = 1814;      // 1.772 * 1024

    if (scale < 1) scale = 1;

    const int out_width = width / scale;
    const int out_height = height / scale;
    const int dest_width = (rotation == 90 || rotation == 270) ? out_height : out_width;

    for (int oy = 0; oy < out_height; oy++) {
        const int sy = oy * scale;
        for (int ox = 0; ox < out_width; ox++) {
            const int sx = ox * scale;

            // Calculate indices into the source planes
            const int uv_index = uv_pixel_stride * (sx / 2) + uv_row_stride * (sy / 2);
            const int y_index = sy * y_row_stride + sx;

            // Get YUV values
            const int yp = y_plane[y_index];
            const int up = u_plane[uv_index] - 128;  // Center U around 0
            const int vp = v_plane[uv_index] - 128;  // Center V around 0

            // Convert to RGB using integer arithmetic
            const int r = yp + (vp * c_v_r) / 1024;
            const int g = yp - (up * c_u_g) / 131072 - (vp * c_v_g) / 131072;
            const int b = yp + (up * c_u_b) / 1024;

            // Map the output-space pixel through the rotation
            int dest_x, dest_y;
            switch (rotation) {
                case 90:
                    dest_x = out_height - 1 - oy;
                    dest_y = ox;
                    break;
                case 180:
                    dest_x = out_width - 1 - ox;
                    dest_y = out_height - 1 - oy;
                    break;
                case 270:
                    dest_x = oy;
                    dest_y = out_width - 1 - ox;
                    break;
                default:
                    dest_x = ox;
                    dest_y = oy;
                    break;
            }

            const int dest_index = (dest_y * dest_width + dest_x) * 4;
            rgb_output[dest_index] = clamp(r, 0, 255);
            rgb_output[dest_index + 1] = clamp(g, 0, 255);
            rgb_output[dest_index + 2] = clamp(b, 0, 255);
            rgb_output[dest_index + 3] = 255;
        }
    }
}
