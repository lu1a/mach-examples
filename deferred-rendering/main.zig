const std = @import("std");
const mach = @import("mach");
const gpu = @import("gpu");
const zm = @import("zmath");
const m3d = @import("model3d");
const assets = @import("assets");

pub const App = @This();

const Vec2 = [2]f32;
const Vec3 = [3]f32;
const Vec4 = [4]f32;
const Mat4 = [4]Vec4;

fn Dimensions2D(comptime T: type) type {
    return struct {
        width: T,
        height: T,
    };
}

const dragon_vertex_count = 5205;
const dragon_cell_count = 11102;

const DragonVertex = extern struct {
    position: Vec3,
    normal: Vec3,
    uv: Vec2,
};

const ViewMatrices = struct {
    up_vector: zm.Vec,
    origin: zm.Vec,
    projection_matrix: zm.Mat,
    view_proj_matrix: zm.Mat,
};

const TextureQuadPass = struct {
    color_attachment: gpu.RenderPassColorAttachment,
    descriptor: gpu.RenderPassDescriptor,
};

const WriteGBufferPass = struct {
    color_attachments: [3]gpu.RenderPassColorAttachment,
    depth_stencil_attachment: gpu.RenderPassDepthStencilAttachment,
    descriptor: gpu.RenderPassDescriptor,
};

const RenderMode = enum(u32) {
    rendering,
    gbuffer_view,
};

const Settings = struct {
    render_mode: RenderMode,
    lights_count: u32,
};

const PressedKeys = packed struct(u16) {
    right: bool = false,
    left: bool = false,
    up: bool = false,
    down: bool = false,
    padding: u12 = undefined,

    pub inline fn areKeysPressed(self: @This()) bool {
        return (self.up or self.down or self.left or self.right);
    }

    pub inline fn clear(self: *@This()) void {
        self.right = false;
        self.left = false;
        self.up = false;
        self.down = false;
    }
};

const Camera = struct {
    const Matrices = struct {
        perspective: Mat4 = [1]Vec4{[1]f32{0.0} ** 4} ** 4,
        view: Mat4 = [1]Vec4{[1]f32{0.0} ** 4} ** 4,
    };

    rotation: Vec3 = .{ 0.0, 0.0, 0.0 },
    position: Vec3 = .{ 0.0, 0.0, 0.0 },
    view_position: Vec4 = .{ 0.0, 0.0, 0.0, 0.0 },
    fov: f32 = 0.0,
    znear: f32 = 0.0,
    zfar: f32 = 0.0,
    rotation_speed: f32 = 0.0,
    movement_speed: f32 = 0.0,
    updated: bool = false,
    matrices: Matrices = .{},

    pub fn calculateMovement(self: *@This(), pressed_keys: PressedKeys) void {
        std.debug.assert(pressed_keys.areKeysPressed());
        const rotation_radians = Vec3{
            toRadians(self.rotation[0]),
            toRadians(self.rotation[1]),
            toRadians(self.rotation[2]),
        };
        var camera_front = zm.Vec{ -zm.cos(rotation_radians[0]) * zm.sin(rotation_radians[1]), zm.sin(rotation_radians[0]), zm.cos(rotation_radians[0]) * zm.cos(rotation_radians[1]), 0 };
        camera_front = zm.normalize3(camera_front);
        if (pressed_keys.up) {
            camera_front[0] *= self.movement_speed;
            camera_front[1] *= self.movement_speed;
            camera_front[2] *= self.movement_speed;
            self.position = Vec3{
                self.position[0] + camera_front[0],
                self.position[1] + camera_front[1],
                self.position[2] + camera_front[2],
            };
        }
        if (pressed_keys.down) {
            camera_front[0] *= self.movement_speed;
            camera_front[1] *= self.movement_speed;
            camera_front[2] *= self.movement_speed;
            self.position = Vec3{
                self.position[0] - camera_front[0],
                self.position[1] - camera_front[1],
                self.position[2] - camera_front[2],
            };
        }
        if (pressed_keys.right) {
            camera_front = zm.cross3(.{ 0.0, 1.0, 0.0, 0.0 }, camera_front);
            camera_front = zm.normalize3(camera_front);
            camera_front[0] *= self.movement_speed;
            camera_front[1] *= self.movement_speed;
            camera_front[2] *= self.movement_speed;
            self.position = Vec3{
                self.position[0] - camera_front[0],
                self.position[1] - camera_front[1],
                self.position[2] - camera_front[2],
            };
        }
        if (pressed_keys.left) {
            camera_front = zm.cross3(.{ 0.0, 1.0, 0.0, 0.0 }, camera_front);
            camera_front = zm.normalize3(camera_front);
            camera_front[0] *= self.movement_speed;
            camera_front[1] *= self.movement_speed;
            camera_front[2] *= self.movement_speed;
            self.position = Vec3{
                self.position[0] + camera_front[0],
                self.position[1] + camera_front[1],
                self.position[2] + camera_front[2],
            };
        }
        self.updateViewMatrix();
    }

    fn updateViewMatrix(self: *@This()) void {
        const rotation_x = zm.rotationX(toRadians(self.rotation[2]));
        const rotation_y = zm.rotationY(toRadians(self.rotation[1]));
        const rotation_z = zm.rotationZ(toRadians(self.rotation[0]));
        const rotation_matrix = zm.mul(rotation_z, zm.mul(rotation_x, rotation_y));

        const translation_matrix: zm.Mat = zm.translationV(.{
            self.position[0],
            self.position[1],
            self.position[2],
            0,
        });
        const view = zm.mul(translation_matrix, rotation_matrix);
        self.matrices.view[0] = view[0];
        self.matrices.view[1] = view[1];
        self.matrices.view[2] = view[2];
        self.matrices.view[3] = view[3];
        self.view_position = .{
            -self.position[0],
            self.position[1],
            -self.position[2],
            0.0,
        };
        self.updated = true;
    }

    pub fn setMovementSpeed(self: *@This(), speed: f32) void {
        self.movement_speed = speed;
    }

    pub fn setPerspective(self: *@This(), fov: f32, aspect: f32, znear: f32, zfar: f32) void {
        self.fov = fov;
        self.znear = znear;
        self.zfar = zfar;
        const perspective = zm.perspectiveFovRhGl(toRadians(fov), aspect, znear, zfar);
        self.matrices.perspective[0] = perspective[0];
        self.matrices.perspective[1] = perspective[1];
        self.matrices.perspective[2] = perspective[2];
        self.matrices.perspective[3] = perspective[3];
    }

    pub fn setRotationSpeed(self: *@This(), speed: f32) void {
        self.rotation_speed = speed;
    }

    pub fn setRotation(self: *@This(), rotation: Vec3) void {
        self.rotation = rotation;
        self.updateViewMatrix();
    }

    pub fn setPosition(self: *@This(), position: Vec3) void {
        self.position = .{
            position[0],
            -position[1],
            position[2],
        };
        self.updateViewMatrix();
    }
};

//
// Constants
//

const max_num_lights = 1024;
const light_data_stride = 8;
const light_extent_min = Vec3{ -50.0, -30.0, -50.0 };
const light_extent_max = Vec3{ 50.0, 30.0, 50.0 };

//
// Member variables
//

const GBuffer = struct {
    texture_2d_float: *gpu.Texture,
    texture_albedo: *gpu.Texture,
    texture_views: [3]*gpu.TextureView,
};

const Lights = struct {
    buffer: *gpu.Buffer,
    buffer_size: u64,
    extent_buffer: *gpu.Buffer,
    extent_buffer_size: u64,
    config_uniform_buffer: *gpu.Buffer,
    config_uniform_buffer_size: u64,
    buffer_bind_group: *gpu.BindGroup,
    buffer_bind_group_layout: *gpu.BindGroupLayout,
    buffer_compute_bind_group: *gpu.BindGroup,
    buffer_compute_bind_group_layout: *gpu.BindGroupLayout,
};

camera: Camera,
queue: *gpu.Queue,
depth_texture: *gpu.Texture,
depth_texture_view: *gpu.TextureView,
pressed_keys: PressedKeys,
dragon_model: []DragonVertex,
vertex_buffer: *gpu.Buffer,
gbuffer: GBuffer,
model_uniform_buffer: *gpu.Buffer,
camera_uniform_buffer: *gpu.Buffer,
surface_size_uniform_buffer: *gpu.Buffer,
lights: Lights,
view_matrices: ViewMatrices,

// Bind groups
scene_uniform_bind_group: *gpu.BindGroup,
surface_size_uniform_bind_group: *gpu.BindGroup,
gbuffer_textures_bind_group: *gpu.BindGroup,

// Bind group layouts
scene_uniform_bind_group_layout: *gpu.BindGroupLayout,
surface_size_uniform_bind_group_layout: *gpu.BindGroupLayout,
gbuffer_textures_bind_group_layout: *gpu.BindGroupLayout,

// Pipelines
write_gbuffers_pipeline: *gpu.RenderPipeline,
gbuffers_debug_view_pipeline: *gpu.RenderPipeline,
deferred_render_pipeline: *gpu.RenderPipeline,
light_update_compute_pipeline: *gpu.ComputePipeline,

// Pipeline layouts
write_gbuffers_pipeline_layout: *gpu.PipelineLayout,
gbuffers_debug_view_pipeline_layout: *gpu.PipelineLayout,
deferred_render_pipeline_layout: *gpu.PipelineLayout,
light_update_compute_pipeline_layout: *gpu.PipelineLayout,

// Render pass descriptor
write_gbuffer_pass: WriteGBufferPass,
texture_quad_pass: TextureQuadPass,
settings: Settings,

screen_dimensions: Dimensions2D(u32),
uniform_buffers_dirty: bool,

//
// Functions
//

pub fn init(app: *App, core: *mach.Core) !void {
    app.queue = core.device.getQueue();
    app.uniform_buffers_dirty = false;
    app.settings.render_mode = .rendering;
    app.settings.lights_count = 128;

    app.screen_dimensions = Dimensions2D(u32){
        .width = core.current_desc.width,
        .height = core.current_desc.height,
    };

    app.camera = Camera{
        .rotation_speed = 1.0,
        .movement_speed = 1.0,
    };

    //
    // Setup Camera
    //
    const aspect_ratio: f32 = @intToFloat(f32, core.current_desc.width) / @intToFloat(f32, core.current_desc.height);
    app.camera.setPosition(.{ 10.0, 6.0, 6.0 });
    app.camera.setRotation(.{ 62.5, 90.0, 0.0 });
    app.camera.setMovementSpeed(0.5);
    app.camera.setPerspective(60.0, aspect_ratio, 0.1, 256.0);
    app.camera.setRotationSpeed(0.25);

    //
    // Load Assets
    //
    app.dragon_model = try loadModelFromFile(std.heap.c_allocator, assets.stanford_dragon.path);
    prepareMeshBuffers(app, core);
    prepareGBufferTextureRenderTargets(app, core, core.current_desc.width, core.current_desc.height);
    prepareDepthTexture(app, core);
    prepareBindGroupLayouts(app, core);
    prepareRenderPipelineLayouts(app, core);
    prepareWriteGBuffersPipeline(app, core);
    prepareGBuffersDebugViewPipeline(app, core);
    prepareDeferredRenderPipeline(app, core);
    setupRenderPasses(app);
    prepareUniformBuffers(app, core);
    prepareComputePipelineLayout(app, core);
    prepareLightUpdateComputePipeline(app, core);
    prepareLights(app, core);
    prepareViewMatrices(app, core);
}

pub fn deinit(app: *App, _: *mach.Core) void {
    app.depth_texture_view.release();
    app.depth_texture.release();
}

pub fn update(app: *App, core: *mach.Core) !void {
    while (core.pollEvent()) |event| {
        switch (event) {
            .key_press => |ev| {
                const key = ev.key;
                if (key == .up or key == .w) app.pressed_keys.up = true;
                if (key == .down or key == .s) app.pressed_keys.down = true;
                if (key == .left or key == .a) app.pressed_keys.left = true;
                if (key == .right or key == .d) app.pressed_keys.right = true;
            },
            else => {},
        }
    }

    std.debug.assert(app.screen_dimensions.width == core.current_desc.width);
    std.debug.assert(app.screen_dimensions.height == core.current_desc.height);

    const command = buildCommandBuffer(app, core);
    app.queue.submit(&[_]*gpu.CommandBuffer{command});

    command.release();
    core.swap_chain.?.present();
    core.swap_chain.?.getCurrentTextureView().release();
}

pub fn resize(app: *App, core: *mach.Core, width: u32, height: u32) !void {
    app.screen_dimensions.width = width;
    app.screen_dimensions.height = height;

    app.depth_texture_view.release();
    app.depth_texture.release();
    app.depth_texture = core.device.createTexture(&gpu.Texture.Descriptor{
        .usage = .{ .render_attachment = true },
        .format = .depth24_plus,
        .sample_count = 1,
        .size = .{
            .width = width,
            .height = height,
            .depth_or_array_layers = 1,
        },
    });
    app.depth_texture_view = app.depth_texture.createView(&gpu.TextureView.Descriptor{
        .format = .depth24_plus,
        .dimension = .dimension_2d,
        .array_layer_count = 1,
        .aspect = .all,
    });
    app.write_gbuffer_pass.depth_stencil_attachment = gpu.RenderPassDepthStencilAttachment{
        .view = app.depth_texture_view,
        .depth_load_op = .clear,
        .depth_store_op = .store,
        .depth_clear_value = 1.0,
        .clear_stencil = 1.0,
        .stencil_clear_value = 1.0,
    };

    app.gbuffer.texture_2d_float.release();
    app.gbuffer.texture_albedo.release();
    app.gbuffer.texture_views[0].release();
    app.gbuffer.texture_views[1].release();
    app.gbuffer.texture_views[2].release();
    prepareGBufferTextureRenderTargets(app, core, width, height);

    const aspect_ratio = @intToFloat(f32, width) / @intToFloat(f32, height);
    app.camera.setPerspective(60.0, aspect_ratio, 0.1, 256.0);
    app.uniform_buffers_dirty = true;

    app.write_gbuffer_pass.color_attachments = [3]gpu.RenderPassColorAttachment{
        .{
            .view = app.gbuffer.texture_views[0],
            .clear_value = .{
                .r = std.math.floatMax(f32),
                .g = std.math.floatMax(f32),
                .b = std.math.floatMax(f32),
                .a = 1.0,
            },
            .load_op = .clear,
            .store_op = .store,
        },
        .{
            .view = app.gbuffer.texture_views[1],
            .clear_value = .{
                .r = 0.0,
                .g = 0.0,
                .b = 1.0,
                .a = 1.0,
            },
            .load_op = .clear,
            .store_op = .store,
        },
        .{
            .view = app.gbuffer.texture_views[2],
            .clear_value = .{
                .r = 0.0,
                .g = 0.0,
                .b = 0.0,
                .a = 1.0,
            },
            .load_op = .clear,
            .store_op = .store,
        },
    };

    app.write_gbuffer_pass.descriptor = gpu.RenderPassDescriptor{
        .color_attachment_count = 3,
        .color_attachments = &app.write_gbuffer_pass.color_attachments,
        .depth_stencil_attachment = &app.write_gbuffer_pass.depth_stencil_attachment,
    };

    prepareViewMatrices(app, core);
}

fn loadModelFromFile(allocator: std.mem.Allocator, model_path: []const u8) ![]DragonVertex {
    var model_file = std.fs.openFileAbsolute(model_path, .{}) catch |err| {
        std.log.err("Failed to load model: '{s}' Error: {}", .{ model_path, err });
        return error.LoadModelFileFailed;
    };
    defer model_file.close();

    var model_data = try model_file.readToEndAllocOptions(allocator, 4048 * 1024, 4048 * 1024, @alignOf(u8), 0);
    defer allocator.free(model_data);

    const m3d_model = m3d.load(model_data, null, null, null) orelse return error.LoadModelFailed;

    const vertex_count = m3d_model.handle.numvertex;
    const vertices = m3d_model.handle.vertex[0..vertex_count];

    const texture_map_count = m3d_model.handle.numtmap;
    const texture_map = m3d_model.handle.tmap[0..texture_map_count];

    const face_count = m3d_model.handle.numface;
    var model = try allocator.alloc(DragonVertex, face_count + 4);

    const scale: f32 = 500.0;
    // TODO: m3d_model.handle.scale
    var i: usize = 0;
    while (i < face_count) : (i += 1) {
        const face = m3d_model.handle.face[i];
        const j: usize = i * 3;

        model[j] = DragonVertex{ .position = .{
            vertices[face.vertex[0]].x * scale,
            vertices[face.vertex[0]].y * scale,
            vertices[face.vertex[0]].z * scale,
        }, .normal = .{
            vertices[face.normal[0]].x,
            vertices[face.normal[0]].y,
            vertices[face.normal[0]].z,
        }, .uv = .{
            texture_map[face.texcoord[0]].u,
            texture_map[face.texcoord[0]].v,
        } };
        model[j + 1] = DragonVertex{ .position = .{
            vertices[face.vertex[1]].x * scale,
            vertices[face.vertex[1]].y * scale,
            vertices[face.vertex[1]].z * scale,
        }, .normal = .{
            vertices[face.normal[1]].x,
            vertices[face.normal[1]].y,
            vertices[face.normal[1]].z,
        }, .uv = .{
            texture_map[face.texcoord[1]].u,
            texture_map[face.texcoord[1]].v,
        } };
        model[j + 2] = DragonVertex{ .position = .{
            vertices[face.vertex[2]].x * scale,
            vertices[face.vertex[2]].y * scale,
            vertices[face.vertex[2]].z * scale,
        }, .normal = .{
            vertices[face.normal[2]].x,
            vertices[face.normal[2]].y,
            vertices[face.normal[2]].z,
        }, .uv = .{
            texture_map[face.texcoord[2]].u,
            texture_map[face.texcoord[2]].v,
        } };
    }

    // Push vertex attributes for an additional ground plane
    model[face_count + 0].position = .{ -100.0, 20.0, -100.0 };
    model[face_count + 1].position = .{ 100.0, 20.0, 100.0 };
    model[face_count + 2].position = .{ -100.0, 20.0, 100.0 };
    model[face_count + 3].position = .{ 100.0, 20.0, -100.0 };
    model[face_count + 0].normal = .{ 0.0, 1.0, 0.0 };
    model[face_count + 1].normal = .{ 0.0, 1.0, 0.0 };
    model[face_count + 2].normal = .{ 0.0, 1.0, 0.0 };
    model[face_count + 3].normal = .{ 0.0, 1.0, 0.0 };
    model[face_count + 0].uv = .{ 0.0, 0.0 };
    model[face_count + 1].uv = .{ 1.0, 1.0 };
    model[face_count + 2].uv = .{ 0.0, 1.0 };
    model[face_count + 3].uv = .{ 1.0, 0.0 };

    std.log.info("Model loaded: {d} faces", .{face_count});
    return model;
}

fn prepareMeshBuffers(app: *App, core: *mach.Core) void {
    const dragon_model = app.dragon_model;
    const buffer_size = dragon_model.len * @sizeOf(DragonVertex);
    app.vertex_buffer = core.device.createBuffer(&.{
        .usage = .{ .vertex = true },
        .size = roundToMultipleOf4(u64, buffer_size),
        .mapped_at_creation = true,
    });
    var mapping = app.vertex_buffer.getMappedRange(DragonVertex, 0, dragon_model.len).?;
    std.mem.copy(DragonVertex, mapping[0..dragon_model.len], dragon_model);
    app.vertex_buffer.unmap();
}

fn prepareGBufferTextureRenderTargets(app: *App, core: *mach.Core, width: u32, height: u32) void {
    var screen_extent = gpu.Extent3D{
        .width = width,
        .height = height,
        .depth_or_array_layers = 2,
    };
    app.gbuffer.texture_2d_float = core.device.createTexture(&.{
        .size = screen_extent,
        .format = .rgba32_float,
        .usage = .{
            .texture_binding = true,
            .render_attachment = true,
        },
    });
    screen_extent.depth_or_array_layers = 1;
    app.gbuffer.texture_albedo = core.device.createTexture(&.{
        .size = screen_extent,
        .format = .bgra8_unorm,
        .usage = .{
            .texture_binding = true,
            .render_attachment = true,
        },
    });

    var texture_view_descriptor = gpu.TextureView.Descriptor{
        .format = .rgba32_float,
        .dimension = .dimension_2d,
        .array_layer_count = 1,
        .aspect = .all,
        .base_array_layer = 0,
    };

    app.gbuffer.texture_views[0] = app.gbuffer.texture_2d_float.createView(&texture_view_descriptor);
    texture_view_descriptor.base_array_layer = 1;
    app.gbuffer.texture_views[1] = app.gbuffer.texture_2d_float.createView(&texture_view_descriptor);
    texture_view_descriptor.base_array_layer = 0;
    texture_view_descriptor.format = .bgra8_unorm;
    app.gbuffer.texture_views[2] = app.gbuffer.texture_albedo.createView(&texture_view_descriptor);
}

fn prepareDepthTexture(app: *App, core: *mach.Core) void {
    const screen_extent = gpu.Extent3D{
        .width = core.current_desc.width,
        .height = core.current_desc.height,
    };
    app.depth_texture = core.device.createTexture(&.{
        .usage = .{ .render_attachment = true },
        .format = .depth24_plus,
        .size = .{
            .width = screen_extent.width,
            .height = screen_extent.height,
            .depth_or_array_layers = 1,
        },
    });
    app.depth_texture_view = app.depth_texture.createView(&gpu.TextureView.Descriptor{
        .format = .depth24_plus,
        .dimension = .dimension_2d,
        .array_layer_count = 1,
        .aspect = .all,
    });
}

fn prepareBindGroupLayouts(app: *App, core: *mach.Core) void {
    {
        const bind_group_layout_entries = [_]gpu.BindGroupLayout.Entry{
            gpu.BindGroupLayout.Entry.texture(0, .{ .fragment = true }, .unfilterable_float, .dimension_2d, false),
            gpu.BindGroupLayout.Entry.texture(1, .{ .fragment = true }, .unfilterable_float, .dimension_2d, false),
            gpu.BindGroupLayout.Entry.texture(2, .{ .fragment = true }, .unfilterable_float, .dimension_2d, false),
        };
        app.gbuffer_textures_bind_group_layout = core.device.createBindGroupLayout(
            &gpu.BindGroupLayout.Descriptor.init(.{
                .entries = &bind_group_layout_entries,
            }),
        );
    }
    {
        const min_binding_size = light_data_stride * max_num_lights * @sizeOf(f32);
        const visibility = gpu.ShaderStageFlags{ .fragment = true, .compute = true };
        const bind_group_layout_entries = [_]gpu.BindGroupLayout.Entry{
            gpu.BindGroupLayout.Entry.buffer(
                0,
                visibility,
                .read_only_storage,
                false,
                min_binding_size,
            ),
            gpu.BindGroupLayout.Entry.buffer(1, visibility, .uniform, false, @sizeOf(u32)),
        };
        app.lights.buffer_bind_group_layout = core.device.createBindGroupLayout(
            &gpu.BindGroupLayout.Descriptor.init(.{
                .entries = &bind_group_layout_entries,
            }),
        );
    }
    {
        const bind_group_layout_entries = [_]gpu.BindGroupLayout.Entry{
            gpu.BindGroupLayout.Entry.buffer(0, .{ .fragment = true }, .uniform, false, @sizeOf(Vec2)),
        };
        app.surface_size_uniform_bind_group_layout = core.device.createBindGroupLayout(
            &gpu.BindGroupLayout.Descriptor.init(.{
                .entries = &bind_group_layout_entries,
            }),
        );
    }
    {
        const bind_group_layout_entries = [_]gpu.BindGroupLayout.Entry{
            gpu.BindGroupLayout.Entry.buffer(0, .{ .vertex = true }, .uniform, false, @sizeOf(Mat4) * 2),
            gpu.BindGroupLayout.Entry.buffer(1, .{ .vertex = true }, .uniform, false, @sizeOf(Mat4)),
        };
        app.scene_uniform_bind_group_layout = core.device.createBindGroupLayout(
            &gpu.BindGroupLayout.Descriptor.init(.{
                .entries = &bind_group_layout_entries,
            }),
        );
    }
    {
        const bind_group_layout_entries = [_]gpu.BindGroupLayout.Entry{
            gpu.BindGroupLayout.Entry.buffer(0, .{ .compute = true }, .storage, false, @sizeOf(f32) * light_data_stride * max_num_lights),
            gpu.BindGroupLayout.Entry.buffer(1, .{ .compute = true }, .uniform, false, @sizeOf(u32)),
            gpu.BindGroupLayout.Entry.buffer(2, .{ .compute = true }, .uniform, false, @sizeOf(Vec4) * 2),
        };
        app.lights.buffer_compute_bind_group_layout = core.device.createBindGroupLayout(
            &gpu.BindGroupLayout.Descriptor.init(.{
                .entries = &bind_group_layout_entries,
            }),
        );
    }
}

fn prepareRenderPipelineLayouts(app: *App, core: *mach.Core) void {
    {
        // Write GBuffers pipeline layout
        const bind_group_layouts = [_]*gpu.BindGroupLayout{app.scene_uniform_bind_group_layout};
        app.write_gbuffers_pipeline_layout = core.device.createPipelineLayout(&gpu.PipelineLayout.Descriptor.init(.{
            .bind_group_layouts = &bind_group_layouts,
        }));
    }
    {
        // GBuffers debug view pipeline layout
        const bind_group_layouts = [_]*gpu.BindGroupLayout{
            app.gbuffer_textures_bind_group_layout,
            app.surface_size_uniform_bind_group_layout,
        };
        app.gbuffers_debug_view_pipeline_layout = core.device.createPipelineLayout(&gpu.PipelineLayout.Descriptor.init(.{
            .bind_group_layouts = &bind_group_layouts,
        }));
    }
    {
        // Deferred render pipeline layout
        const bind_group_layouts = [_]*gpu.BindGroupLayout{
            app.gbuffer_textures_bind_group_layout,
            app.lights.buffer_bind_group_layout,
            app.surface_size_uniform_bind_group_layout,
        };
        app.deferred_render_pipeline_layout = core.device.createPipelineLayout(&gpu.PipelineLayout.Descriptor.init(.{
            .bind_group_layouts = &bind_group_layouts,
        }));
    }
}

fn prepareWriteGBuffersPipeline(app: *App, core: *mach.Core) void {
    const color_target_states = [_]gpu.ColorTargetState{
        .{ .format = .rgba32_float },
        .{ .format = .rgba32_float },
        .{ .format = .bgra8_unorm },
    };

    const write_gbuffers_vertex_buffer_layout = gpu.VertexBufferLayout.init(.{
        .array_stride = @sizeOf(DragonVertex),
        .step_mode = .vertex,
        .attributes = &.{
            .{ .format = .float32x3, .offset = @offsetOf(DragonVertex, "position"), .shader_location = 0 },
            .{ .format = .float32x3, .offset = @offsetOf(DragonVertex, "normal"), .shader_location = 1 },
            .{ .format = .float32x2, .offset = @offsetOf(DragonVertex, "uv"), .shader_location = 2 },
        },
    });

    const vertex_shader_module = core.device.createShaderModuleWGSL("vertexWriteGBuffers.wgsl", @embedFile("vertexWriteGBuffers.wgsl"));

    const fragment_shader_module = core.device.createShaderModuleWGSL("fragmentWriteGBuffers.wgsl", @embedFile("fragmentWriteGBuffers.wgsl"));

    const pipeline_descriptor = gpu.RenderPipeline.Descriptor{
        .layout = app.write_gbuffers_pipeline_layout,
        .primitive = .{
            .cull_mode = .back,
        },
        .depth_stencil = &.{
            .format = .depth24_plus,
            .depth_write_enabled = true,
            .depth_compare = .less,
        },
        .vertex = gpu.VertexState.init(.{
            .module = vertex_shader_module,
            .entry_point = "main",
            .buffers = &.{write_gbuffers_vertex_buffer_layout},
        }),
        .fragment = &gpu.FragmentState.init(.{
            .module = fragment_shader_module,
            .entry_point = "main",
            .targets = &color_target_states,
        }),
    };
    app.write_gbuffers_pipeline = core.device.createRenderPipeline(&pipeline_descriptor);

    vertex_shader_module.release();
    fragment_shader_module.release();
}

fn prepareGBuffersDebugViewPipeline(app: *App, core: *mach.Core) void {
    const blend_component_descriptor = gpu.BlendComponent{
        .operation = .add,
        .src_factor = .one,
        .dst_factor = .zero,
    };

    const color_target_state = gpu.ColorTargetState{
        .format = core.swap_chain_format,
        .blend = &.{
            .color = blend_component_descriptor,
            .alpha = blend_component_descriptor,
        },
    };

    const vertex_shader_module = core.device.createShaderModuleWGSL(
        "vertexTextureQuad.wgsl",
        @embedFile("vertexTextureQuad.wgsl"),
    );
    const fragment_shader_module = core.device.createShaderModuleWGSL(
        "fragmentGBuffersDebugView.wgsl",
        @embedFile("fragmentGBuffersDebugView.wgsl"),
    );
    const pipeline_descriptor = gpu.RenderPipeline.Descriptor{
        .layout = app.gbuffers_debug_view_pipeline_layout,
        .primitive = .{
            .cull_mode = .back,
        },
        .vertex = gpu.VertexState.init(.{
            .module = vertex_shader_module,
            .entry_point = "main",
        }),
        .fragment = &gpu.FragmentState.init(.{
            .module = fragment_shader_module,
            .entry_point = "main",
            .targets = &.{color_target_state},
        }),
    };
    app.gbuffers_debug_view_pipeline = core.device.createRenderPipeline(&pipeline_descriptor);
    vertex_shader_module.release();
    fragment_shader_module.release();
}

fn prepareDeferredRenderPipeline(app: *App, core: *mach.Core) void {
    const blend_component_descriptor = gpu.BlendComponent{
        .operation = .add,
        .src_factor = .one,
        .dst_factor = .zero,
    };

    const color_target_state = gpu.ColorTargetState{
        .format = .bgra8_unorm,
        .blend = &.{
            .color = blend_component_descriptor,
            .alpha = blend_component_descriptor,
        },
    };

    const vertex_shader_module = core.device.createShaderModuleWGSL(
        "vertexTextureQuad.wgsl",
        @embedFile("vertexTextureQuad.wgsl"),
    );
    const fragment_shader_module = core.device.createShaderModuleWGSL(
        "fragmentDeferredRendering.wgsl",
        @embedFile("fragmentDeferredRendering.wgsl"),
    );
    const pipeline_descriptor = gpu.RenderPipeline.Descriptor{
        .layout = app.deferred_render_pipeline_layout,
        .primitive = .{
            .cull_mode = .back,
        },
        .vertex = gpu.VertexState.init(.{
            .module = vertex_shader_module,
            .entry_point = "main",
        }),
        .fragment = &gpu.FragmentState.init(.{
            .module = fragment_shader_module,
            .entry_point = "main",
            .targets = &.{color_target_state},
        }),
    };
    app.deferred_render_pipeline = core.device.createRenderPipeline(&pipeline_descriptor);
    vertex_shader_module.release();
    fragment_shader_module.release();
}

fn setupRenderPasses(app: *App) void {
    {
        // Write GBuffer pass
        app.write_gbuffer_pass.color_attachments = [3]gpu.RenderPassColorAttachment{
            .{
                .view = app.gbuffer.texture_views[0],
                .clear_value = .{
                    .r = std.math.floatMax(f32),
                    .g = std.math.floatMax(f32),
                    .b = std.math.floatMax(f32),
                    .a = 1.0,
                },
                .load_op = .clear,
                .store_op = .store,
            },
            .{
                .view = app.gbuffer.texture_views[1],
                .clear_value = .{
                    .r = 0.0,
                    .g = 0.0,
                    .b = 1.0,
                    .a = 1.0,
                },
                .load_op = .clear,
                .store_op = .store,
            },
            .{
                .view = app.gbuffer.texture_views[2],
                .clear_value = .{
                    .r = 0.0,
                    .g = 0.0,
                    .b = 0.0,
                    .a = 1.0,
                },
                .load_op = .clear,
                .store_op = .store,
            },
        };

        app.write_gbuffer_pass.depth_stencil_attachment = gpu.RenderPassDepthStencilAttachment{
            .view = app.depth_texture_view,
            .depth_load_op = .clear,
            .depth_store_op = .store,
            .depth_clear_value = 1.0,
            .clear_depth = 1.0,
            .clear_stencil = 1.0,
            .stencil_clear_value = 1.0,
        };

        app.write_gbuffer_pass.descriptor = gpu.RenderPassDescriptor{
            .color_attachment_count = 3,
            .color_attachments = &app.write_gbuffer_pass.color_attachments,
            .depth_stencil_attachment = &app.write_gbuffer_pass.depth_stencil_attachment,
        };
    }
    {
        // Texture Quad Pass
        app.texture_quad_pass.color_attachment = gpu.RenderPassColorAttachment{
            .clear_value = .{
                .r = 0.0,
                .g = 0.0,
                .b = 0.0,
                .a = 1.0,
            },
            .load_op = .clear,
            .store_op = .store,
        };

        app.texture_quad_pass.descriptor = gpu.RenderPassDescriptor{
            .color_attachment_count = 1,
            .color_attachments = &[_]gpu.RenderPassColorAttachment{app.texture_quad_pass.color_attachment},
        };
    }
}

fn prepareUniformBuffers(app: *App, core: *mach.Core) void {
    {
        // Config uniform buffer
        app.lights.config_uniform_buffer_size = @sizeOf(u32);
        app.lights.config_uniform_buffer = core.device.createBuffer(&.{
            .usage = .{ .copy_dst = true, .uniform = true },
            .size = app.lights.config_uniform_buffer_size,
            .mapped_at_creation = true,
        });
        var config_data = app.lights.config_uniform_buffer.getMappedRange(u32, 0, 1).?;
        config_data[0] = app.settings.lights_count;
        app.lights.config_uniform_buffer.unmap();
    }
    {
        // Model uniform buffer
        app.model_uniform_buffer = core.device.createBuffer(&.{
            .usage = .{ .copy_dst = true, .uniform = true },
            .size = @sizeOf(Mat4) * 2,
        });
    }
    {
        // Camera uniform buffer
        app.camera_uniform_buffer = core.device.createBuffer(&.{
            .usage = .{ .copy_dst = true, .uniform = true },
            .size = @sizeOf(Mat4),
        });
    }
    {
        // Scene uniform bind group
        const bind_group_entries = [_]gpu.BindGroup.Entry{
            .{
                .binding = 0,
                .buffer = app.model_uniform_buffer,
                .size = @sizeOf(Mat4) * 2,
            },
            .{
                .binding = 1,
                .buffer = app.camera_uniform_buffer,
                .size = @sizeOf(Mat4),
            },
        };
        app.scene_uniform_bind_group = core.device.createBindGroup(
            &gpu.BindGroup.Descriptor.init(.{
                .layout = app.write_gbuffers_pipeline.getBindGroupLayout(0),
                .entries = &bind_group_entries,
            }),
        );
    }
    {
        // Surface size uniform buffer
        app.surface_size_uniform_buffer = core.device.createBuffer(&.{
            .usage = .{ .copy_dst = true, .uniform = true },
            .size = @sizeOf(f32) * 4, // TODO: Verify type
        });
    }
    {
        // Surface size uniform bind group
        const bind_group_entries = [_]gpu.BindGroup.Entry{
            .{
                .binding = 0,
                .buffer = app.surface_size_uniform_buffer,
                .size = @sizeOf(f32) * 2, // TODO: Verify type
            },
        };
        app.surface_size_uniform_bind_group = core.device.createBindGroup(
            &gpu.BindGroup.Descriptor.init(.{
                .layout = app.surface_size_uniform_bind_group_layout,
                .entries = &bind_group_entries,
            }),
        );
    }
    {
        // GBuffer textures bind group
        const bind_group_entries = [_]gpu.BindGroup.Entry{
            gpu.BindGroup.Entry.textureView(0, app.gbuffer.texture_views[0]),
            gpu.BindGroup.Entry.textureView(1, app.gbuffer.texture_views[1]),
            gpu.BindGroup.Entry.textureView(2, app.gbuffer.texture_views[2]),
        };
        app.gbuffer_textures_bind_group = core.device.createBindGroup(
            &gpu.BindGroup.Descriptor.init(.{
                .layout = app.gbuffer_textures_bind_group_layout,
                .entries = &bind_group_entries,
            }),
        );
    }
}

fn prepareComputePipelineLayout(app: *App, core: *mach.Core) void {
    const bind_group_layouts = [_]*gpu.BindGroupLayout{app.lights.buffer_compute_bind_group_layout};
    app.light_update_compute_pipeline_layout = core.device.createPipelineLayout(&gpu.PipelineLayout.Descriptor.init(.{
        .bind_group_layouts = &bind_group_layouts,
    }));
}

fn prepareLightUpdateComputePipeline(app: *App, core: *mach.Core) void {
    const shader_module = core.device.createShaderModuleWGSL("lightUpdate.wgsl", @embedFile("lightUpdate.wgsl"));
    app.light_update_compute_pipeline = core.device.createComputePipeline(&gpu.ComputePipeline.Descriptor{
        .compute = gpu.ProgrammableStageDescriptor{
            .module = shader_module,
            .entry_point = "main",
        },
        .layout = app.light_update_compute_pipeline_layout,
    });
    shader_module.release();
}

fn prepareLights(app: *App, core: *mach.Core) void {
    // Lights data are uploaded in a storage buffer
    // which could be updated/culled/etc. with a compute shader
    const extent = comptime Vec3{
        light_extent_max[0] - light_extent_min[0],
        light_extent_max[1] - light_extent_min[1],
        light_extent_max[2] - light_extent_min[2],
    };
    app.lights.buffer_size = @sizeOf(f32) * light_data_stride * max_num_lights;
    app.lights.buffer = core.device.createBuffer(&.{
        .usage = .{ .storage = true },
        .size = app.lights.buffer_size,
        .mapped_at_creation = true,
    });
    // We randomly populate lights randomly in a box range
    // And simply move them along y-axis per frame to show they are dynamic
    // lightings
    var light_data = app.lights.buffer.getMappedRange(f32, 0, light_data_stride * max_num_lights).?;

    var xoroshiro = std.rand.Xoroshiro128.init(9273853284918);
    const rng = std.rand.Random.init(
        &xoroshiro,
        std.rand.Xoroshiro128.fill,
    );
    var i: usize = 0;
    var offset: usize = 0;
    while (i < max_num_lights) : (i += 1) {
        offset = light_data_stride * i;
        // Position
        light_data[offset + 0] = rng.float(f32) * extent[0] + light_extent_min[0];
        light_data[offset + 1] = rng.float(f32) * extent[1] + light_extent_min[1];
        light_data[offset + 2] = rng.float(f32) * extent[2] + light_extent_min[2];
        light_data[offset + 3] = 1.0;
        // Color
        light_data[offset + 4] = rng.float(f32) * 2.0;
        light_data[offset + 5] = rng.float(f32) * 2.0;
        light_data[offset + 6] = rng.float(f32) * 2.0;
        // Radius
        light_data[offset + 7] = 20.0;
    }
    app.lights.buffer.unmap();
    //
    // Lights extent buffer
    //
    app.lights.extent_buffer_size = @sizeOf(f32) * light_data_stride * max_num_lights;
    app.lights.extent_buffer = core.device.createBuffer(&.{
        .usage = .{ .uniform = true, .copy_dst = true },
        .size = app.lights.extent_buffer_size,
    });
    var light_extent_data = [1]f32{0.0} ** 8;
    std.mem.copy(f32, light_extent_data[0..3], &light_extent_min);
    std.mem.copy(f32, light_extent_data[4..7], &light_extent_max);
    app.queue.writeBuffer(
        app.lights.extent_buffer,
        0,
        &light_extent_data,
    );
    //
    // Lights buffer bind group
    //
    {
        const bind_group_entries = [_]gpu.BindGroup.Entry{
            .{
                .binding = 0,
                .buffer = app.lights.buffer,
                .size = app.lights.buffer_size,
            },
            .{
                .binding = 1,
                .buffer = app.lights.config_uniform_buffer,
                .size = app.lights.config_uniform_buffer_size,
            },
        };
        app.lights.buffer_bind_group = core.device.createBindGroup(
            &gpu.BindGroup.Descriptor.init(.{
                .layout = app.lights.buffer_bind_group_layout,
                .entries = &bind_group_entries,
            }),
        );
    }
    //
    // Lights buffer compute bind group
    //
    {
        const bind_group_entries = [_]gpu.BindGroup.Entry{
            .{
                .binding = 0,
                .buffer = app.lights.buffer,
                .size = app.lights.buffer_size,
            },
            .{
                .binding = 1,
                .buffer = app.lights.config_uniform_buffer,
                .size = app.lights.config_uniform_buffer_size,
            },
            .{
                .binding = 2,
                .buffer = app.lights.extent_buffer,
                .size = app.lights.extent_buffer_size,
            },
        };
        app.lights.buffer_compute_bind_group = core.device.createBindGroup(
            &gpu.BindGroup.Descriptor.init(.{
                .layout = app.light_update_compute_pipeline.getBindGroupLayout(0),
                .entries = &bind_group_entries,
            }),
        );
    }
}

fn prepareViewMatrices(app: *App, core: *mach.Core) void {
    const screen_dimensions = Dimensions2D(f32){
        .width = @intToFloat(f32, core.current_desc.width),
        .height = @intToFloat(f32, core.current_desc.height),
    };
    // Scene matrices
    const aspect: f32 = screen_dimensions.width / screen_dimensions.height;
    const fov: f32 = 2.0 * std.math.pi / 5.0;
    const znear: f32 = 1.0;
    const zfar: f32 = 2000.0;
    app.view_matrices.projection_matrix = zm.perspectiveFovRhGl(fov, aspect, znear, zfar);
    const eye_position = zm.Vec{ 0.0, 50.0, -100.0, 1.0 };
    app.view_matrices.up_vector = zm.Vec{ 0.0, 1.0, 0.0, 0.0 };
    app.view_matrices.origin = zm.Vec{ 0.0, 0.0, 0.0, 0.0 };
    const view_matrix = zm.lookAtRh(
        eye_position,
        app.view_matrices.origin,
        app.view_matrices.up_vector,
    );
    const view_proj_matrix: zm.Mat = zm.mul(app.view_matrices.projection_matrix, view_matrix);
    // Move the model so it's centered.
    const vec1 = zm.Vec{ 0.0, -5.0, 0.0, 0.0 };
    const vec2 = zm.Vec{ 0.0, -40.0, 0.0, 0.0 };
    const model_matrix = zm.mul(zm.translationV(vec1), zm.translationV(vec2));
    app.queue.writeBuffer(
        app.camera_uniform_buffer,
        0,
        &view_proj_matrix,
    );
    app.queue.writeBuffer(
        app.model_uniform_buffer,
        0,
        &model_matrix,
    );
    // Normal model data
    const invert_transpose_model_matrix = zm.transpose(zm.inverse(model_matrix));
    app.queue.writeBuffer(
        app.model_uniform_buffer,
        64,
        &invert_transpose_model_matrix,
    );
    // Pass the surface size to shader to help sample from gBuffer textures using coord
    const surface_size = Vec2{ screen_dimensions.width, screen_dimensions.height };
    app.queue.writeBuffer(
        app.surface_size_uniform_buffer,
        0,
        &surface_size,
    );
}

fn buildCommandBuffer(app: *App, core: *mach.Core) *gpu.CommandBuffer {
    const back_buffer_view = core.swap_chain.?.getCurrentTextureView();
    const encoder = core.device.createCommandEncoder(null);
    defer encoder.release();

    std.debug.assert(app.screen_dimensions.width == core.current_desc.width);
    std.debug.assert(app.screen_dimensions.height == core.current_desc.height);

    const dimensions = Dimensions2D(f32){
        .width = @intToFloat(f32, core.current_desc.width),
        .height = @intToFloat(f32, core.current_desc.height),
    };

    {
        // Write position, normal, albedo etc. data to gBuffers
        // app.write_gbuffer_pass.descriptor.view = back_buffer_view;
        const pass = encoder.beginRenderPass(&app.write_gbuffer_pass.descriptor);
        pass.setViewport(
            0,
            0,
            dimensions.width,
            dimensions.height,
            0.0,
            1.0,
        );
        pass.setScissorRect(0, 0, core.current_desc.width, core.current_desc.height);
        pass.setPipeline(app.write_gbuffers_pipeline);
        pass.setBindGroup(0, app.scene_uniform_bind_group, null);
        pass.setVertexBuffer(0, app.vertex_buffer, 0, @sizeOf(DragonVertex) * app.dragon_model.len);
        pass.draw(@intCast(u32, app.dragon_model.len), 1, 0, 0);
        // pass.drawIndexed(
        //     app.index_count,
        //     1, // instance_count
        //     0, // first_index
        //     0, // base_vertex
        //     0, // first_instance
        // );
        pass.end();
        pass.release();
    }
    {
        // Update lights position
        const pass = encoder.beginComputePass(null);
        pass.setPipeline(app.light_update_compute_pipeline);
        pass.setBindGroup(0, app.lights.buffer_compute_bind_group, null);
        pass.dispatchWorkgroups(@divExact(max_num_lights, 64), 1, 1);
        pass.end();
        pass.release();
    }
    app.texture_quad_pass.color_attachment.view = back_buffer_view;
    app.texture_quad_pass.descriptor = gpu.RenderPassDescriptor{
        .color_attachment_count = 1,
        .color_attachments = &[_]gpu.RenderPassColorAttachment{app.texture_quad_pass.color_attachment},
    };
    const pass = encoder.beginRenderPass(&app.texture_quad_pass.descriptor);

    switch (app.settings.render_mode) {
        .gbuffer_view => {
            // GBuffers debug view
            // Left: position
            // Middle: normal
            // Right: albedo (use uv to mimic a checkerboard texture)
            pass.setPipeline(app.gbuffers_debug_view_pipeline);
            pass.setBindGroup(0, app.gbuffer_textures_bind_group, null);
            pass.setBindGroup(1, app.surface_size_uniform_bind_group, null);
            pass.draw(6, 1, 0, 0);
        },
        else => {
            // Deferred rendering
            pass.setPipeline(app.deferred_render_pipeline);
            pass.setBindGroup(0, app.gbuffer_textures_bind_group, null);
            pass.setBindGroup(1, app.lights.buffer_bind_group, null);
            pass.setBindGroup(2, app.surface_size_uniform_bind_group, null);
            pass.draw(6, 1, 0, 0);
        },
    }
    pass.end();
    pass.release();

    // TODO: Draw UI
    return encoder.finish(null);
}

fn computeNormals(app: *App, core: *mach.Core) void {
    _ = app;
    _ = core;
    // TODO: Implement
}

inline fn roundToMultipleOf4(comptime T: type, value: T) T {
    return (value + 3) & ~@as(T, 3);
}

inline fn toRadians(degrees: f32) f32 {
    return degrees * (std.math.pi / 180.0);
}
