
#import "GLTFAssetReader.h"

#define CGLTF_IMPLEMENTATION
#import "cgltf.h"

@interface GLTFUniqueNameGenerator : NSObject
- (NSString *)nextUniqueNameWithPrefix:(NSString *)prefix;
@end

@interface GLTFUniqueNameGenerator ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *countsForPrefixes;
@end

@implementation GLTFUniqueNameGenerator

- (instancetype)init {
    if (self = [super init]) {
        _countsForPrefixes = [NSMutableDictionary dictionary];
    }
    return self;
}

- (NSString *)nextUniqueNameWithPrefix:(NSString *)prefix {
    NSNumber *existingCount = self.countsForPrefixes[prefix];
    if (existingCount) {
        self.countsForPrefixes[prefix] = @(existingCount.integerValue + 1);
        return [NSString stringWithFormat:@"%@%@", prefix, existingCount];
    }
    self.countsForPrefixes[prefix] = @(1);
    return [NSString stringWithFormat:@"%@%d", prefix, 1];
}

@end

static NSDictionary *GLTFExtensionsFromCGLTF(cgltf_extension *extensions, size_t extensionCount) {
    return @{}; // TODO: Recursively convert to extension object
}

static GLTFComponentType GLTFComponentTypeForType(cgltf_component_type type) {
    return (GLTFComponentType)type;
}

static GLTFValueDimension GLTFDimensionForAccessorType(cgltf_type type) {
    return (GLTFValueDimension)type;
}

static GLTFAlphaMode GLTFAlphaModeFromMode(cgltf_alpha_mode mode) {
    return (GLTFAlphaMode)mode;
}

static GLTFPrimitiveType GLTFPrimitiveTypeFromType(cgltf_primitive_type type) {
    return (GLTFPrimitiveType)type;
}

static GLTFInterpolationMode GLTFInterpolationModeForType(cgltf_interpolation_type type) {
    return (GLTFInterpolationMode)type;
}

static NSString *GLTFTargetPathForPath(cgltf_animation_path_type path) {
    switch (path) {
        case cgltf_animation_path_type_rotation: return @"rotation";
        case cgltf_animation_path_type_scale: return @"scale";
        case cgltf_animation_path_type_translation: return @"translation";
        case cgltf_animation_path_type_weights: return @"weights";
        default: return @"";
    }
}

@interface GLTFAssetReader () {
    cgltf_data *gltf;
}
@property (class, nonatomic, readonly) dispatch_queue_t loaderQueue;
@property (nonatomic, nullable, strong) NSURL *assetURL;
@property (nonatomic, strong) GLTFAsset *asset;
@end

static dispatch_queue_t _loaderQueue;

@implementation GLTFAssetReader

+ (dispatch_queue_t)loaderQueue {
    if (_loaderQueue == nil) {
        _loaderQueue = dispatch_queue_create("com.metalbyexample.gltfkit2.asset-loader", DISPATCH_QUEUE_CONCURRENT);
    }
    return _loaderQueue;
}

+ (void)loadAssetWithURL:(NSURL *)url
                 options:(NSDictionary<GLTFAssetLoadingOption, id> *)options
                 handler:(nullable GLTFAssetLoadingHandler)handler
{
    dispatch_async(self.loaderQueue, ^{
        GLTFAssetReader *loader = [[GLTFAssetReader alloc] init];
        [loader syncLoadAssetWithURL:url data:nil options:options handler:handler];
    });
}

+ (void)loadAssetWithData:(NSData *)data
                  options:(NSDictionary<GLTFAssetLoadingOption, id> *)options
                  handler:(nullable GLTFAssetLoadingHandler)handler
{
    dispatch_async(self.loaderQueue, ^{
        GLTFAssetReader *loader = [[GLTFAssetReader alloc] init];
        [loader syncLoadAssetWithURL:nil data:data options:options handler:handler];
    });
}

- (void)syncLoadAssetWithURL:(NSURL * _Nullable)assetURL
                        data:(NSData * _Nullable)data
                     options:(NSDictionary<GLTFAssetLoadingOption, id> *)options
                     handler:(nullable GLTFAssetLoadingHandler)handler
{
    self.assetURL = assetURL;

    BOOL stop = NO;
    NSData *internalData = data ?: [NSData dataWithContentsOfURL:assetURL];
    if (internalData == nil) {
        handler(1.0, GLTFAssetStatusError, nil, nil, &stop);
        return;
    }
    
    cgltf_options parseOptions = {0};
    //cgltf_data *gltf = NULL;
    cgltf_result result = cgltf_parse(&parseOptions, internalData.bytes, internalData.length, &gltf);
    
    if (result != cgltf_result_success) {
        handler(1.0, GLTFAssetStatusError, nil, nil, &stop);
    } else {        
        result = cgltf_load_buffers(&parseOptions, gltf, assetURL.fileSystemRepresentation);
        if (result != cgltf_result_success) {
            handler(1.0, GLTFAssetStatusError, nil, nil, &stop);
        } else {
            [self convertAsset];
            handler(1.0, GLTFAssetStatusComplete, self.asset, nil, &stop);
        }
    }
    
    cgltf_free(gltf);
}

- (NSArray *)convertBuffers {
    NSMutableArray *buffers = [NSMutableArray arrayWithCapacity:gltf->buffers_count];
    for (int i = 0; i < gltf->buffers_count; ++i) {
        cgltf_buffer *b = gltf->buffers + i;
        GLTFBuffer *buffer = nil;
        if (b->data) {
            buffer = [[GLTFBuffer alloc] initWithData:[NSData dataWithBytes:b->data length:b->size]];
        } else {
            buffer = [[GLTFBuffer alloc] initWithLength:b->size];
        }
        [buffers addObject:buffer];
    }
    return buffers;
}

- (NSArray *)convertBufferViews {
    NSMutableArray *bufferViews = [NSMutableArray arrayWithCapacity:gltf->buffer_views_count];
    for (int i = 0; i < gltf->buffer_views_count; ++i) {
        cgltf_buffer_view *bv = gltf->buffer_views + i;
        size_t bufferIndex = bv->buffer - gltf->buffers;
        GLTFBufferView *bufferView = [[GLTFBufferView alloc] initWithBuffer:self.asset.buffers[bufferIndex]
                                                                     length:bv->size
                                                                     offset:bv->offset
                                                                     stride:bv->stride];
        [bufferViews addObject:bufferView];
    }
    return bufferViews;
}

- (NSArray *)convertAccessors
{
    NSMutableArray *accessors = [NSMutableArray arrayWithCapacity:gltf->accessors_count];
    for (int i = 0; i < gltf->accessors_count; ++i) {
        cgltf_accessor *a = gltf->accessors + i;
        GLTFBufferView *bufferView = nil;
        if (a->buffer_view) {
            size_t bufferViewIndex = a->buffer_view - gltf->buffer_views;
            bufferView = self.asset.bufferViews[bufferViewIndex];
        }
        GLTFAccessor *accessor = [[GLTFAccessor alloc] initWithBufferView:bufferView
                                                                   offset:a->offset
                                                            componentType:GLTFComponentTypeForType(a->component_type)
                                                                dimension:GLTFDimensionForAccessorType(a->type)
                                                                    count:a->count
                                                               normalized:a->normalized];
        // TODO: Convert min/max values
        // TODO: Sparse
        [accessors addObject:accessor];
    }
    return accessors;
}

- (NSArray *)convertTextureSamplers
{
    NSMutableArray *textureSamplers = [NSMutableArray arrayWithCapacity:gltf->samplers_count];
    for (int i = 0; i < gltf->samplers_count; ++i) {
        cgltf_sampler *s = gltf->samplers + i;
        GLTFTextureSampler *sampler = [GLTFTextureSampler new];
        sampler.magFilter = s->mag_filter;
        sampler.minMipFilter = s->min_filter;
        sampler.wrapS = s->wrap_s;
        sampler.wrapT = s->wrap_t;
        [textureSamplers addObject:sampler];
    }
    return textureSamplers;
}

- (NSArray *)convertImages
{
    NSMutableArray *images = [NSMutableArray arrayWithCapacity:gltf->images_count];
    for (int i = 0; i < gltf->images_count; ++i) {
        cgltf_image *img = gltf->images + i;
        GLTFImage *image = nil;
        if (img->buffer_view) {
            size_t bufferViewIndex = img->buffer_view - gltf->buffer_views;
            GLTFBufferView *bufferView = self.asset.bufferViews[bufferViewIndex];
            NSString *mime = [NSString stringWithUTF8String:img->mime_type ? img->mime_type : "image/jpeg"];
            image = [[GLTFImage alloc] initWithBufferView:bufferView mimeType:mime];
        } else {
            assert(img->uri);
            NSURL *baseURI = [self.asset.url URLByDeletingLastPathComponent];
            NSURL *imageURI = [baseURI URLByAppendingPathComponent:[NSString stringWithUTF8String:img->uri]];
            image = [[GLTFImage alloc] initWithURI:imageURI];
        }
        [images addObject:image];
    }
    return images;
}

- (NSArray *)convertTextures
{
    NSMutableArray *textures = [NSMutableArray arrayWithCapacity:gltf->textures_count];
    for (int i = 0; i < gltf->textures_count; ++i) {
        cgltf_texture *t = gltf->textures + i;
        GLTFImage *image = nil;
        GLTFTextureSampler *sampler = nil;
        if (t->image) {
            size_t imageIndex = t->image - gltf->images;
            image = self.asset.images[imageIndex];
        }
        if (t->sampler) {
            size_t samplerIndex = t->sampler - gltf->samplers;
            sampler = self.asset.samplers[samplerIndex];
        }
        GLTFTexture *texture = [[GLTFTexture alloc] initWithSource:image];
        texture.sampler = sampler;
        [textures addObject:texture];
    }
    return textures;
}

- (GLTFTextureParams *)textureParamsFromTextureView:(cgltf_texture_view *)tv {
    size_t textureIndex = tv->texture - gltf->textures;
    GLTFTextureParams *params = [GLTFTextureParams new];
    params.texture = self.asset.textures[textureIndex];
    params.scale = tv->scale;
    params.texCoord = tv->texcoord;
    // TODO: transform
    return params;
}

- (NSArray *)convertMaterials
{
    NSMutableArray *materials = [NSMutableArray arrayWithCapacity:gltf->materials_count];
    for (int i = 0; i < gltf->materials_count; ++i) {
        cgltf_material *m = gltf->materials + i;
        GLTFMaterial *material = [GLTFMaterial new];
        if (m->normal_texture.texture) {
            material.normalTexture = [self textureParamsFromTextureView:&m->normal_texture];
        }
        if (m->occlusion_texture.texture) {
            material.occlusionTexture = [self textureParamsFromTextureView:&m->occlusion_texture];
        }
        if (m->emissive_texture.texture) {
            material.emissiveTexture = [self textureParamsFromTextureView:&m->emissive_texture];
        }
        float *emissive = m->emissive_factor;
        material.emissiveFactor = (simd_float3){ emissive[0], emissive[1], emissive[2] };
        material.alphaMode = GLTFAlphaModeFromMode(m->alpha_mode);
        material.alphaCutoff = m->alpha_cutoff;
        material.doubleSided = (BOOL)m->double_sided;
        // TODO: unlit
        // TODO: PBR
        // TODO: sheen
        // TODO: clearcoat
        [materials addObject:material];
    }
    return materials;
}

- (NSArray *)convertMeshes
{
    NSMutableArray *meshes = [NSMutableArray arrayWithCapacity:gltf->meshes_count];
    for (int i = 0; i < gltf->meshes_count; ++i) {
        cgltf_mesh *m = gltf->meshes + i;
        GLTFMesh *mesh = [GLTFMesh new];
        NSMutableArray *primitives = [NSMutableArray array];
        for (int j = 0; j < m->primitives_count; ++j) {
            cgltf_primitive *p = m->primitives + j;
            GLTFPrimitiveType type = GLTFPrimitiveTypeFromType(p->type);
            NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
            for (int k = 0; k < p->attributes_count; ++k) {
                cgltf_attribute *a = p->attributes + k;
                NSString *attrName = [NSString stringWithUTF8String:a->name];
                size_t attrIndex = a->data - gltf->accessors;
                GLTFAccessor *attrAccessor = self.asset.accessors[attrIndex];
                attributes[attrName] = attrAccessor;
            }
            GLTFPrimitive *primitive = nil;
            if (p->indices) {
                size_t accessorIndex = p->indices - gltf->accessors;
                GLTFAccessor *indices = self.asset.accessors[accessorIndex];
                primitive = [[GLTFPrimitive alloc] initWithPrimitiveType:type attributes:attributes indices:indices];
            } else {
                primitive = [[GLTFPrimitive alloc] initWithPrimitiveType:type attributes:attributes];
            }
            if (p->material) {
                size_t materialIndex = p->material - gltf->materials;
                primitive.material = self.asset.materials[materialIndex];
            }
            [primitives addObject:primitive];
        }
        mesh.primitives = primitives;
        // TODO: morph targets
        [meshes addObject:mesh];
    }
    return meshes;
}

- (NSArray *)convertCameras
{
    NSMutableArray *cameras = [NSMutableArray array];
    for (int i = 0; i < gltf->cameras_count; ++i) {
        cgltf_camera *c = gltf->cameras + i;
        GLTFCamera *camera = nil;
        if (c->type == cgltf_camera_type_orthographic) {
            GLTFOrthographicProjectionParams *params = [[GLTFOrthographicProjectionParams alloc] init];
            params.xMag = c->data.orthographic.xmag;
            params.yMag = c->data.orthographic.ymag;
            GLTFCamera *camera = [[GLTFCamera alloc] initWithOrthographicProjection:params];
            camera.zNear = c->data.orthographic.znear;
            camera.zFar = c->data.orthographic.zfar;
        } else if (c->type == cgltf_camera_type_perspective) {
            GLTFPerspectiveProjectionParams *params = [[GLTFPerspectiveProjectionParams alloc] init];
            params.yFOV = c->data.perspective.yfov;
            params.aspectRatio = c->data.perspective.aspect_ratio;
            GLTFCamera *camera = [[GLTFCamera alloc] initWithPerspectiveProjection:params];
            camera.zNear = c->data.perspective.znear;
            camera.zFar = c->data.perspective.zfar;
        } else {
            camera = [[GLTFCamera alloc] init]; // Got an invalid camera, so just make a dummy to occupy the slot
        }
        [cameras addObject:camera];
    }
    return cameras;
}

- (NSArray *)convertNodes
{
    NSMutableArray *nodes = [NSMutableArray array];
    for (int i = 0; i < gltf->nodes_count; ++i) {
        cgltf_node *n = gltf->nodes + i;
        GLTFNode *node = [[GLTFNode alloc] init];
        if (n->camera) {
            size_t cameraIndex = n->camera - gltf->cameras;
            node.camera = self.asset.cameras[cameraIndex];
        }
        //if (n->light) {
        //    size_t lightIndex = n->light = gltf->lights;
        //    node.light = self.asset.lights[lightIndex];
        //}
        if (n->mesh) {
            size_t meshIndex = n->mesh - gltf->meshes;
            node.mesh = self.asset.meshes[meshIndex];
        }
        if (n->has_matrix) {
            simd_float4x4 transform;
            memcpy(&transform, n->matrix, sizeof(float) * 16);
            node.matrix = transform;
            // TODO: decompose transform to T,R,S
        } else {
            if (n->has_translation) {
                node.translation = simd_make_float3(n->translation[0], n->translation[1], n->translation[2]);
            }
            if (n->has_scale) {
                node.scale = simd_make_float3(n->scale[0], n->scale[1], n->scale[2]);
            }
            if (n->has_rotation) {
                node.rotation = simd_quaternion(n->rotation[0], n->rotation[1], n->rotation[2], n->rotation[3]);
            }
            float m[16];
            cgltf_node_transform_local(n, &m[0]);
            simd_float4x4 transform;
            memcpy(&transform, m, sizeof(float) * 16);
            node.matrix = transform;
        }
        // TODO: morph target weights
        [nodes addObject:node];
    }
    for (int i = 0; i < gltf->nodes_count; ++i) {
        cgltf_node *n = gltf->nodes + i;
        GLTFNode *node = nodes[i];
        if (n->children_count > 0) {
            NSMutableArray *children = [NSMutableArray arrayWithCapacity:n->children_count];
            for (int j = 0; j < n->children_count; ++j) {
                size_t childIndex = n->children[j] - gltf->nodes;
                GLTFNode *child = nodes[childIndex];
                [children addObject:child];
            }
            node.childNodes = children; // Automatically creates inverse child->parent reference
        }
    }
    return nodes;
}

- (NSArray *)convertSkins
{
    NSMutableArray *skins = [NSMutableArray array];
    for (int i = 0; i < gltf->skins_count; ++i) {
        cgltf_skin *s = gltf->skins + i;
        NSMutableArray *joints = [NSMutableArray arrayWithCapacity:s->joints_count];
        for (int j = 0; j < s->joints_count; ++j) {
            size_t jointIndex = s->joints[j] - gltf->nodes;
            GLTFNode *joint = self.asset.nodes[jointIndex];
            [joints addObject:joint];
        }
        GLTFSkin *skin = [[GLTFSkin alloc] initWithJoints:joints];
        if (s->inverse_bind_matrices) {
            size_t ibmIndex = s->inverse_bind_matrices - gltf->accessors;
            GLTFAccessor *ibms = self.asset.accessors[ibmIndex];
            skin.inverseBindMatrices = ibms;
        }
        if (s->skeleton) {
            size_t skeletonIndex = s->skeleton - gltf->nodes;
            GLTFNode *skeletonRoot = self.asset.nodes[skeletonIndex];
            skin.skeleton = skeletonRoot;
        }
        [skins addObject:skin];
    }
    return skins;
}

- (NSArray *)convertAnimations
{
    NSMutableArray *animations = [NSMutableArray array];
    for (int i = 0; i < gltf->animations_count; ++i) {
        cgltf_animation *a = gltf->animations + i;
        NSMutableArray<GLTFAnimationSampler *> *samplers = [NSMutableArray arrayWithCapacity:a->samplers_count];
        for (int j = 0; j < a->samplers_count; ++j) {
            cgltf_animation_sampler *s = a->samplers + j;
            size_t inputIndex = s->input - gltf->accessors;
            GLTFAccessor *input = self.asset.accessors[inputIndex];
            size_t outputIndex = s->output - gltf->accessors;
            GLTFAccessor *output = self.asset.accessors[outputIndex];
            GLTFAnimationSampler *sampler = [[GLTFAnimationSampler alloc] initWithInput:input output:output];
            sampler.interpolationMode = GLTFInterpolationModeForType(s->interpolation);
            [samplers addObject:sampler];
        }
        NSMutableArray<GLTFAnimationChannel *> *channels = [NSMutableArray arrayWithCapacity:a->channels_count];
        for (int j = 0; j < a->channels_count; ++j) {
            cgltf_animation_channel *c = a->channels + j;
            NSString *targetPath = GLTFTargetPathForPath(c->target_path);
            GLTFAnimationTarget *target = [[GLTFAnimationTarget alloc] initWithPath:targetPath];
            if (c->target_node) {
                size_t targetIndex = c->target_node - gltf->nodes;
                GLTFNode *targetNode = self.asset.nodes[targetIndex];
                target.node = targetNode;
            }
            size_t samplerIndex = c->sampler - a->samplers;
            GLTFAnimationSampler *sampler = samplers[samplerIndex];
            GLTFAnimationChannel *channel = [[GLTFAnimationChannel alloc] initWithTarget:target sampler:sampler];
            [channels addObject:channel];
        }
        GLTFAnimation *animation = [[GLTFAnimation alloc] initWithChannels:channels samplers:samplers];
        [animations addObject:animation];
    }
    return animations;
}

- (NSArray *)convertScenes
{
    NSMutableArray *scenes = [NSMutableArray array];
    for (int i = 0; i < gltf->scenes_count; ++i) {
        cgltf_scene *s = gltf->scenes + i;
        GLTFScene *scene = [GLTFScene new];
        NSMutableArray *rootNodes = [NSMutableArray arrayWithCapacity:s->nodes_count];
        for (int j = 0; j < s->nodes_count; ++j) {
            size_t nodeIndex = s->nodes[j] - gltf->nodes;
            GLTFNode *node = self.asset.nodes[nodeIndex];
            [rootNodes addObject:node];
        }
        scene.nodes = rootNodes;
        [scenes addObject:scene];
    }
    return scenes;
}

- (void)convertAsset {
    self.asset = [GLTFAsset new];
    self.asset.url = self.assetURL;
    cgltf_asset *meta = &gltf->asset;
    if (meta->copyright) {
        self.asset.copyright = [NSString stringWithUTF8String:meta->copyright];
    }
    if (meta->generator) {
        self.asset.generator = [NSString stringWithUTF8String:meta->generator];
    }
    if (meta->min_version) {
        self.asset.minVersion = [NSString stringWithUTF8String:meta->min_version];
    }
    if (meta->version) {
        self.asset.version = [NSString stringWithUTF8String:meta->version];
    }
    // TODO: extensions meta
    // TODO: extensions/extras
    self.asset.buffers = [self convertBuffers];
    self.asset.bufferViews = [self convertBufferViews];
    self.asset.accessors = [self convertAccessors];
    self.asset.samplers = [self convertTextureSamplers];
    self.asset.images = [self convertImages];
    self.asset.textures = [self convertTextures];
    self.asset.materials = [self convertMaterials];
    self.asset.meshes = [self convertMeshes];
    self.asset.cameras = [self convertCameras];
    //asset.lights = GLTFLightsFromCGLTF(gltf);
    self.asset.nodes = [self convertNodes];
    self.asset.skins = [self convertSkins];
    // TODO: resolve node->skeleton relationships
    self.asset.animations = [self convertAnimations];
    self.asset.scenes = [self convertScenes];
    if (gltf->scene) {
        size_t sceneIndex = gltf->scene - gltf->scenes;
        GLTFScene *scene = self.asset.scenes[sceneIndex];
        self.asset.defaultScene = scene;
    } else {
        if (self.asset.scenes.count > 0) {
            self.asset.defaultScene = self.asset.scenes.firstObject;
        }
    }
}

@end