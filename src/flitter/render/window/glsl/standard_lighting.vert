#version 330

in vec3 model_position;
in vec3 model_normal;
in vec2 model_uv;
in mat4 model_matrix;
in mat3 model_normal_matrix;

in vec4 material_albedo;
in vec4 material_emissive;
in vec4 material_properties;

out vec3 world_position;
out vec3 world_normal;
out vec2 texture_uv;
noperspective out vec2 screen_coord;

flat out vec4 fragment_albedo;
flat out vec4 fragment_emissive;
flat out vec4 fragment_properties;

uniform mat4 pv_matrix;

void main() {
    world_position = (model_matrix * vec4(model_position, 1)).xyz;
    gl_Position = pv_matrix * vec4(world_position, 1);
    screen_coord = (gl_Position.xy / gl_Position.w + 1) / 2;
    world_normal = model_normal_matrix * model_normal;
    texture_uv = model_uv;
    fragment_albedo = material_albedo;
    fragment_emissive = material_emissive;
    fragment_properties = material_properties;
}
