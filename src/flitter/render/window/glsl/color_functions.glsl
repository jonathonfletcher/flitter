
vec3 srgb_transfer(vec3 c) {
    c = clamp(c, 0.0, 1.0);
    return mix(12.92 * c, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, ceil(c - 0.0031308));
}

float srgb_luminance(vec3 c) {
    return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

vec3 tonemap_reinhard(vec3 c, float whitepoint) {
    vec3 cd = c / (1.0 + c);
    if (whitepoint > 1.0) {
        cd *= (1.0 + c / (whitepoint * whitepoint));
    }
    return cd;
}

vec3 tonemap_aces(vec3 color)
{
    // This function based on https://github.com/TheRealMJP/BakingLab/blob/master/BakingLab/ACES.hlsl
    //
    color = mat3(0.59719, 0.076, 0.0284, 0.35458, 0.90834, 0.13383, 0.04823, 0.01566, 0.83777) * color;
    color = (color * (color + 0.0245786) - 0.000090537) / (color * (0.983729 * color + 0.4329510) + 0.238081);
    return mat3(1.60475, -0.10208, -0.00327, -0.53108, 1.10813, -0.07276, -0.07367, -0.00605, 1.07602) * color;
}