
#import "GLTFSceneKit.h"

#if TARGET_OS_IOS
typedef UIImage NSUIImage;
#elif TARGET_OS_OSX
typedef NSImage NSUIImage;
#else
#error "Unsupported operating system. Cannot determine suitable image class"
#endif

static const float LumensPerCandela = 1.0 / (4.0 * M_PI);

static float GLTFDegFromRad(float rad) {
    return rad * (180.0 / M_PI);
}

static SCNFilterMode GLTFSCNFilterModeForMagFilter(GLTFMagFilter filter) {
    switch (filter) {
        case GLTFMagFilterNearest:
            return SCNFilterModeNearest;
        default:
            return SCNFilterModeLinear;
    }
}

static void GLTFSCNGetFilterModeForMinMipFilter(GLTFMinMipFilter filter,
                                                SCNFilterMode *outMinFilter,
                                                SCNFilterMode *outMipFilter)
{
    if (outMinFilter) {
        switch (filter) {
            case GLTFMinMipFilterNearest:
            case GLTFMinMipFilterNearestNearest:
            case GLTFMinMipFilterNearestLinear:
                *outMinFilter = SCNFilterModeNearest;
                break;
            case GLTFMinMipFilterLinear:
            case GLTFMinMipFilterLinearNearest:
            case GLTFMinMipFilterLinearLinear:
            default:
                *outMinFilter = SCNFilterModeLinear;
                break;
        }
    }
    if (outMipFilter) {
        switch (filter) {
            case GLTFMinMipFilterNearest:
            case GLTFMinMipFilterLinear:
            case GLTFMinMipFilterNearestNearest:
            case GLTFMinMipFilterLinearNearest:
                *outMipFilter = SCNFilterModeNearest;
                break;
            case GLTFMinMipFilterNearestLinear:
            case GLTFMinMipFilterLinearLinear:
            default:
                *outMipFilter = SCNFilterModeLinear;
                break;
        }
    }
}

static SCNWrapMode GLTFSCNWrapModeForMode(GLTFAddressMode mode) {
    switch (mode) {
        case GLTFAddressModeClampToEdge:
            return SCNWrapModeClamp;
        case GLTFAddressModeRepeat:
            return SCNWrapModeRepeat;
        case GLTFAddressModeMirroredRepeat:
            return SCNWrapModeMirror;
    }
}

static NSData *GLTFLineIndexDataForLineLoopIndexData(NSData *lineLoopIndexData,
                                                     int lineLoopIndexCount,
                                                     int bytesPerIndex) {
    if (lineLoopIndexCount < 2) {
        return nil;
    }

    int lineIndexCount = 2 * lineLoopIndexCount;
    size_t bufferSize = lineIndexCount * bytesPerIndex;
    unsigned char *lineIndices = malloc(bufferSize);
    unsigned char *lineIndicesCursor = lineIndices;
    unsigned char *lineLoopIndices = (unsigned char *)lineLoopIndexData.bytes;

    // Create a line from the last index element to the first index element.
    int lastLineIndexOffset = (lineIndexCount - 1) * bytesPerIndex;
    memcpy(lineIndicesCursor, lineLoopIndices, bytesPerIndex);
    memcpy(lineIndicesCursor + lastLineIndexOffset, lineLoopIndices, bytesPerIndex);
    lineIndicesCursor += bytesPerIndex;

    // Duplicate indices in-between to fill in the loop.
    for (int i = 1; i < lineLoopIndexCount; ++i) {
        memcpy(lineIndicesCursor, lineLoopIndices + (i * bytesPerIndex), bytesPerIndex);
        lineIndicesCursor += bytesPerIndex;
        memcpy(lineIndicesCursor, lineLoopIndices + (i * bytesPerIndex), bytesPerIndex);
        lineIndicesCursor += bytesPerIndex;
    }

    return [NSData dataWithBytesNoCopy:lineIndices
                                length:bufferSize
                          freeWhenDone:YES];
}

static NSData *GLTFLineIndexDataForLineStripIndexData(NSData *lineStripIndexData,
                                                      int lineStripIndexCount,
                                                      int bytesPerIndex) {
    if (lineStripIndexCount < 2) {
        return nil;
    }

    int lineIndexCount = 2 * (lineStripIndexCount - 1);
    size_t bufferSize = lineIndexCount * bytesPerIndex;
    unsigned char *lineIndices = malloc(bufferSize);
    unsigned char *lineIndicesCursor = lineIndices;
    unsigned char *lineStripIndices = (unsigned char *)lineStripIndexData.bytes;

    // Place the first and last indices.
    int lastLineIndexOffset = (lineIndexCount - 1) * bytesPerIndex;
    int lastLineStripIndexOffset = (lineStripIndexCount - 1) * bytesPerIndex;
    memcpy(lineIndicesCursor, lineStripIndices, bytesPerIndex);
    memcpy(lineIndicesCursor + lastLineIndexOffset,
           lineStripIndices + lastLineStripIndexOffset,
           bytesPerIndex);
    lineIndicesCursor += bytesPerIndex;

    // Duplicate all indices in-between.
    for (int i = 1; i < lineStripIndexCount; ++i) {
        memcpy(lineIndicesCursor, lineStripIndices + (i * bytesPerIndex), bytesPerIndex);
        lineIndicesCursor += bytesPerIndex;
        memcpy(lineIndicesCursor, lineStripIndices + (i * bytesPerIndex), bytesPerIndex);
        lineIndicesCursor += bytesPerIndex;
    }

    return [NSData dataWithBytesNoCopy:lineIndices
                                length:bufferSize
                          freeWhenDone:YES];
}

static NSData *GLTFTrianglesIndexDataForTriangleFanIndexData(NSData *triangleFanIndexData,
                                                             int triangleFanIndexCount,
                                                             int bytesPerIndex) {
    if (triangleFanIndexCount < 3) {
        return nil;
    }

    int trianglesIndexCount = 3 * (triangleFanIndexCount - 2);
    size_t bufferSize = trianglesIndexCount * bytesPerIndex;
    unsigned char *trianglesIndices = malloc(bufferSize);
    unsigned char *trianglesIndicesCursor = trianglesIndices;
    unsigned char *triangleFanIndices = (unsigned char *)triangleFanIndexData.bytes;

    for (int i = 1; i < triangleFanIndexCount; ++i) {
        memcpy(trianglesIndicesCursor, triangleFanIndices, bytesPerIndex);
        trianglesIndicesCursor += bytesPerIndex;
        memcpy(trianglesIndicesCursor, triangleFanIndices + (i * bytesPerIndex), 2 * bytesPerIndex);
        trianglesIndicesCursor += 2 * bytesPerIndex;
    }

    return [NSData dataWithBytesNoCopy:trianglesIndices
                                length:bufferSize
                          freeWhenDone:YES];
}

static SCNGeometryElement *GLTFSCNGeometryElementForIndexData(NSData *indexData,
                                                              int indexCount,
                                                              int bytesPerIndex,
                                                              GLTFPrimitive *primitive) {
    SCNGeometryPrimitiveType primitiveType;
    int primitiveCount;
    switch (primitive.primitiveType) {
        case GLTFPrimitiveTypePoints:
            primitiveType = SCNGeometryPrimitiveTypePoint;
            primitiveCount = indexCount;
            break;
        case GLTFPrimitiveTypeLines:
            primitiveCount = indexCount / 2;
            primitiveType = SCNGeometryPrimitiveTypeLine;
            break;
        case GLTFPrimitiveTypeLineLoop:
            primitiveCount = indexCount;
            primitiveType = SCNGeometryPrimitiveTypeLine;
            indexData = GLTFLineIndexDataForLineLoopIndexData(indexData, indexCount, bytesPerIndex);
            break;
        case GLTFPrimitiveTypeLineStrip:
            primitiveCount = indexCount - 1;
            primitiveType = SCNGeometryPrimitiveTypeLine;
            indexData = GLTFLineIndexDataForLineStripIndexData(indexData, indexCount, bytesPerIndex);
            break;
        case GLTFPrimitiveTypeTriangles:
            primitiveCount = indexCount / 3;
            primitiveType = SCNGeometryPrimitiveTypeTriangles;
            break;
        case GLTFPrimitiveTypeTriangleStrip:
            primitiveCount = indexCount - 2; // TODO: Handle primitive restart?
            primitiveType = SCNGeometryPrimitiveTypeTriangleStrip;
            break;
        case GLTFPrimitiveTypeTriangleFan:
            primitiveCount = indexCount - 2;
            primitiveType = SCNGeometryPrimitiveTypeTriangles;
            indexData = GLTFTrianglesIndexDataForTriangleFanIndexData(indexData, indexCount, bytesPerIndex);
            break;
    }

    return [SCNGeometryElement geometryElementWithData:indexData
                                         primitiveType:primitiveType
                                        primitiveCount:primitiveCount
                                         bytesPerIndex:bytesPerIndex];
}

static NSString *GLTFSCNGeometrySourceSemanticForSemantic(NSString *name) {
    if ([name isEqualToString:GLTFAttributeSemanticPosition]) {
        return SCNGeometrySourceSemanticVertex;
    } else if ([name isEqualToString:GLTFAttributeSemanticNormal]) {
        return SCNGeometrySourceSemanticNormal;
    } else if ([name isEqualToString:GLTFAttributeSemanticTangent]) {
        return SCNGeometrySourceSemanticTangent;
    } else if ([name hasPrefix:@"TEXCOORD_"]) {
        return SCNGeometrySourceSemanticTexcoord;
    } else if ([name hasPrefix:@"COLOR_"]) {
        return SCNGeometrySourceSemanticColor;
    } else if ([name hasPrefix:@"JOINTS_"]) {
        return SCNGeometrySourceSemanticBoneIndices;
    } else if ([name hasPrefix:@"WEIGHTS_"]) {
        return SCNGeometrySourceSemanticBoneWeights;
    }
    return name;
}

static void GLTFConfigureSCNMaterialProperty(SCNMaterialProperty *property, GLTFTextureParams *textureParams) {
    static GLTFTextureSampler *defaultSampler = nil;
    if (defaultSampler == nil) {
        defaultSampler = [[GLTFTextureSampler alloc] init];
        defaultSampler.magFilter = GLTFMagFilterLinear;
        defaultSampler.minMipFilter = GLTFMinMipFilterLinearLinear;
        defaultSampler.wrapS = GLTFAddressModeRepeat;
        defaultSampler.wrapT = GLTFAddressModeRepeat;
    }
    GLTFTextureSampler *sampler = textureParams.texture.sampler ?: defaultSampler;
    property.intensity = textureParams.scale;
    property.magnificationFilter = GLTFSCNFilterModeForMagFilter(sampler.magFilter);
    SCNFilterMode minFilter, mipFilter;
    GLTFSCNGetFilterModeForMinMipFilter(sampler.minMipFilter, &minFilter, &mipFilter);
    property.minificationFilter = minFilter;
    property.mipFilter = mipFilter;
    property.wrapS = GLTFSCNWrapModeForMode(sampler.wrapS);
    property.wrapT = GLTFSCNWrapModeForMode(sampler.wrapT);
    property.mappingChannel = textureParams.texCoord;
    if (textureParams.transform) {
        property.contentsTransform = SCNMatrix4FromMat4(textureParams.transform.matrix);
        // clgtf doesn't distinguish between texture transforms that override the mapping
        // channel to 0 and texture transforms that don't override, so we have to assume
        // that if the mapping channel looks like an override to channel 0, it isn't.
        if (textureParams.transform.texCoord > 0) {
            property.mappingChannel = textureParams.transform.texCoord;
        }
    }
}

static NSData *GLTFPackedUInt16DataFromPackedUInt8(UInt8 *bytes, size_t count) {
    size_t bufferSize = sizeof(UInt16) * count;
    UInt16 *shorts = malloc(bufferSize);
    // This is begging to be parallelized. Can this be done with Accelerate?
    for (int i = 0; i < count; ++i) {
        shorts[i] = (UInt16)bytes[i];
    }
    return [NSData dataWithBytesNoCopy:shorts length:bufferSize freeWhenDone:YES];
}

static NSData *GLTFSCNPackedDataForAccessor(GLTFAccessor *accessor) {
    GLTFBufferView *bufferView = accessor.bufferView;
    GLTFBuffer *buffer = bufferView.buffer;
    size_t bytesPerComponent = GLTFBytesPerComponentForComponentType(accessor.componentType);
    size_t componentCount = GLTFComponentCountForDimension(accessor.dimension);
    size_t elementSize = bytesPerComponent * componentCount;
    size_t bufferLength = elementSize * accessor.count;
    void *bytes = malloc(elementSize * accessor.count);
    void *bufferViewBaseAddr = (void *)buffer.data.bytes + bufferView.offset;
    if (bufferView.stride == 0 || bufferView.stride == elementSize) {
        // Fast path
        memcpy(bytes, bufferViewBaseAddr + accessor.offset, accessor.count * elementSize);
    } else {
        // Slow path, element by element
        for (int i = 0; i < accessor.count; ++i) {
            void *src = bufferViewBaseAddr + (i * bufferView.stride ?: elementSize);
            void *dest = bytes + (i * elementSize);
            memcpy(dest, src, elementSize);
        }
    }
    if (accessor.sparse) {
        assert(accessor.sparse.indexComponentType == GLTFComponentTypeUnsignedShort ||
               accessor.sparse.indexComponentType == GLTFComponentTypeUnsignedInt);
        const void *baseSparseIndexBufferViewPtr = accessor.sparse.indices.buffer.data.bytes +
                                                   accessor.sparse.indices.offset;
        const void *baseSparseIndexAccessorPtr = baseSparseIndexBufferViewPtr + accessor.sparse.indexOffset;

        const void *baseValueBufferViewPtr = accessor.sparse.values.buffer.data.bytes + accessor.sparse.values.offset;
        const void *baseSrcPtr = baseValueBufferViewPtr + accessor.sparse.valueOffset;
        const size_t srcValueStride = accessor.sparse.values.stride ?: elementSize;

        void *baseDestPtr = bytes;

        if (accessor.sparse.indexComponentType == GLTFComponentTypeUnsignedShort) {
            const UInt16 *sparseIndices = (UInt16 *)baseSparseIndexAccessorPtr;
            for (int i = 0; i < accessor.sparse.count; ++i) {
                UInt16 sparseIndex = sparseIndices[i];
                memcpy(baseDestPtr + sparseIndex * elementSize, baseSrcPtr + (i * srcValueStride), elementSize);
            }
        } else if (accessor.sparse.indexComponentType == GLTFComponentTypeUnsignedInt) {
            const UInt32 *sparseIndices = (UInt32 *)baseSparseIndexAccessorPtr;
            for (int i = 0; i < accessor.sparse.count; ++i) {
                UInt32 sparseIndex = sparseIndices[i];
                memcpy(baseDestPtr + sparseIndex * elementSize, baseSrcPtr + (i * srcValueStride), elementSize);
            }
        }
    }
    return [NSData dataWithBytesNoCopy:bytes length:bufferLength freeWhenDone:YES];
}

static NSArray<NSNumber *> *GLTFKeyTimeArrayForAccessor(GLTFAccessor *accessor, NSTimeInterval maxKeyTime) {
    // TODO: This is actually not assured by the spec. We should convert from normalized int types when necessary
    assert(accessor.componentType == GLTFComponentTypeFloat);
    assert(accessor.dimension == GLTFValueDimensionScalar);
    NSMutableArray *values = [NSMutableArray arrayWithCapacity:accessor.count];
    const void *bufferViewBaseAddr = accessor.bufferView.buffer.data.bytes + accessor.bufferView.offset;
    float scale = (maxKeyTime > 0) ? (1.0f / maxKeyTime) : 1.0f;
    for (int i = 0; i < accessor.count; ++i) {
        const float *x = bufferViewBaseAddr + (i * (accessor.bufferView.stride ?: sizeof(float))) + accessor.offset;
        NSNumber *value = @(x[0] * scale);
        [values addObject:value];
    }
    return values;
}

static SCNGeometrySource *GLTFSCNGeometrySourceForAccessor(GLTFAccessor *accessor, NSString *semanticName) {
    size_t bytesPerComponent = GLTFBytesPerComponentForComponentType(accessor.componentType);
    size_t componentCount = GLTFComponentCountForDimension(accessor.dimension);
    size_t elementSize = bytesPerComponent * componentCount;
    NSData *attrData = GLTFSCNPackedDataForAccessor(accessor);
    return [SCNGeometrySource geometrySourceWithData:attrData
                                            semantic:GLTFSCNGeometrySourceSemanticForSemantic(semanticName)
                                         vectorCount:accessor.count
                                     floatComponents:(accessor.componentType == GLTFComponentTypeFloat)
                                 componentsPerVector:componentCount
                                   bytesPerComponent:bytesPerComponent
                                          dataOffset:0
                                          dataStride:elementSize];
}

static NSArray<NSValue *> *GLTFSCNVector3ArrayForAccessor(GLTFAccessor *accessor) {
    // TODO: This is actually not assured by the spec. We should convert from normalized int types when necessary
    assert(accessor.componentType == GLTFComponentTypeFloat);
    assert(accessor.dimension == GLTFValueDimensionVector3);
    NSMutableArray *values = [NSMutableArray arrayWithCapacity:accessor.count];
    const void *bufferViewBaseAddr = accessor.bufferView.buffer.data.bytes + accessor.bufferView.offset;
    const size_t elementSize = sizeof(float) * 3;
    for (int i = 0; i < accessor.count; ++i) {
        const float *xyz = bufferViewBaseAddr + (i * (accessor.bufferView.stride ?: elementSize)) + accessor.offset;
        NSValue *value = [NSValue valueWithSCNVector3:SCNVector3Make(xyz[0], xyz[1], xyz[2])];
        [values addObject:value];
    }
    return values;
}

static NSArray<NSValue *> *GLTFSCNVector4ArrayForAccessor(GLTFAccessor *accessor) {
    // TODO: This is actually not assured by the spec. We should convert from normalized int types when necessary
    assert(accessor.componentType == GLTFComponentTypeFloat);
    assert(accessor.dimension == GLTFValueDimensionVector4);
    NSMutableArray *values = [NSMutableArray arrayWithCapacity:accessor.count];
    const void *bufferViewBaseAddr = accessor.bufferView.buffer.data.bytes + accessor.bufferView.offset;
    const size_t elementSize = sizeof(float) * 4;
    for (int i = 0; i < accessor.count; ++i) {
        const float *xyzw = bufferViewBaseAddr + (i * (accessor.bufferView.stride ?: elementSize)) + accessor.offset;
        NSValue *value = [NSValue valueWithSCNVector4:SCNVector4Make(xyzw[0], xyzw[1], xyzw[2], xyzw[3])];
        [values addObject:value];
    }
    return values;
}

static NSArray<NSValue *> *GLTFSCNMatrix4ArrayFromAccessor(GLTFAccessor *accessor) {
    assert(accessor.componentType == GLTFComponentTypeFloat);
    assert(accessor.dimension == GLTFValueDimensionMatrix4);
    NSMutableArray *values = [NSMutableArray arrayWithCapacity:accessor.count];
    const void *bufferViewBaseAddr = accessor.bufferView.buffer.data.bytes + accessor.bufferView.offset;
    const size_t elementSize = sizeof(float) * 16;
    for (int i = 0; i < accessor.count; ++i) {
        const float *M = bufferViewBaseAddr + (i * (accessor.bufferView.stride ?: elementSize)) + accessor.offset;
        SCNMatrix4 m;
        m.m11 = M[ 0]; m.m12 = M[ 1]; m.m13 = M[ 2]; m.m14 = M[ 3];
        m.m21 = M[ 4]; m.m22 = M[ 5]; m.m23 = M[ 6]; m.m24 = M[ 7];
        m.m31 = M[ 8]; m.m32 = M[ 9]; m.m33 = M[10]; m.m34 = M[11];
        m.m41 = M[12]; m.m42 = M[13]; m.m43 = M[14]; m.m44 = M[15];
        NSValue *value = [NSValue valueWithSCNMatrix4:m];
        [values addObject:value];
    }
    return values;
}

@implementation GLTFSCNAnimationChannel
@end

@implementation GLTFSCNAnimation
@end

@implementation SCNScene (GLTFSceneKit)

+ (instancetype)sceneWithGLTFAsset:(GLTFAsset *)asset
{
    NSMutableDictionary<NSUUID *, NSUIImage *> *imagesForIdentfiers = [NSMutableDictionary dictionary];
    for (GLTFImage *image in asset.images) {
        NSUIImage *uiImage = nil;
        if (image.uri) {
            uiImage = [[NSUIImage alloc] initWithContentsOfURL:image.uri];
        } else {
            CGImageRef cgImage = [image newCGImage];
            uiImage = [[NSUIImage alloc] initWithCGImage:cgImage size:NSZeroSize];
            CFRelease(cgImage);
        }
        imagesForIdentfiers[image.identifier] = uiImage;
    }
    
    CGColorSpaceRef colorSpaceLinearSRGB = CGColorSpaceCreateWithName(kCGColorSpaceLinearSRGB);
    
    SCNMaterial *defaultMaterial = [SCNMaterial material];
    defaultMaterial.lightingModelName = SCNLightingModelPhysicallyBased;
    defaultMaterial.locksAmbientWithDiffuse = YES;
    CGFloat defaultBaseColorFactor[] = { 1.0, 1.0, 1.0, 1.0 };
    defaultMaterial.diffuse.contents = (__bridge_transfer id)CGColorCreate(colorSpaceLinearSRGB, &defaultBaseColorFactor[0]);
    defaultMaterial.metalness.contents = @(1.0);
    defaultMaterial.roughness.contents = @(1.0);

    NSMutableDictionary <NSUUID *, SCNMaterial *> *materialsForIdentifiers = [NSMutableDictionary dictionary];
    for (GLTFMaterial *material in asset.materials) {
        SCNMaterial *scnMaterial = [SCNMaterial new];
        scnMaterial.locksAmbientWithDiffuse = YES;
        if (material.isUnlit) {
            scnMaterial.lightingModelName = SCNLightingModelConstant;
        } else if (material.metallicRoughness || material.specularGlossiness) {
            scnMaterial.lightingModelName = SCNLightingModelPhysicallyBased;
        } else {
            scnMaterial.lightingModelName = SCNLightingModelBlinn;
        }
        if (material.metallicRoughness) {
            //TODO: How to represent base color/emissive factor, etc., when textures are present?
            if (material.metallicRoughness.baseColorTexture) {
                GLTFTextureParams *baseColorTexture = material.metallicRoughness.baseColorTexture;
                SCNMaterialProperty *baseColorProperty = scnMaterial.diffuse;
                baseColorProperty.contents = imagesForIdentfiers[baseColorTexture.texture.source.identifier];
                GLTFConfigureSCNMaterialProperty(baseColorProperty, baseColorTexture);
                // This is pretty awful, but we have no other straightforward way of supporting
                // base color textures and factors simultaneously
                simd_float4 rgba = material.metallicRoughness.baseColorFactor;
                CGFloat rgbad[] = { rgba[0], rgba[1], rgba[2], rgba[3] };
                scnMaterial.multiply.contents = (__bridge_transfer id)CGColorCreate(colorSpaceLinearSRGB, rgbad);
            } else {
                SCNMaterialProperty *baseColorProperty = scnMaterial.diffuse;
                simd_float4 rgba = material.metallicRoughness.baseColorFactor;
                CGFloat rgbad[] = { rgba[0], rgba[1], rgba[2], rgba[3] };
                baseColorProperty.contents = (__bridge_transfer id)CGColorCreate(colorSpaceLinearSRGB, rgbad);
            }
            if (material.metallicRoughness.metallicRoughnessTexture) {
                GLTFTextureParams *metallicRoughnessTexture = material.metallicRoughness.metallicRoughnessTexture;
                id metallicRoughnessImage = imagesForIdentfiers[metallicRoughnessTexture.texture.source.identifier];
                
                SCNMaterialProperty *metallicProperty = scnMaterial.metalness;
                metallicProperty.contents = metallicRoughnessImage;
                GLTFConfigureSCNMaterialProperty(metallicProperty, metallicRoughnessTexture);
                metallicProperty.textureComponents = SCNColorMaskBlue;
                
                SCNMaterialProperty *roughnessProperty = scnMaterial.roughness;
                roughnessProperty.contents = metallicRoughnessImage;
                GLTFConfigureSCNMaterialProperty(roughnessProperty, metallicRoughnessTexture);
                roughnessProperty.textureComponents = SCNColorMaskGreen;
            } else {
                SCNMaterialProperty *metallicProperty = scnMaterial.metalness;
                metallicProperty.contents = @(material.metallicRoughness.metallicFactor);
                SCNMaterialProperty *roughnessProperty = scnMaterial.roughness;
                roughnessProperty.contents = @(material.metallicRoughness.roughnessFactor);
            }
        } else if (material.specularGlossiness) {
            if (material.specularGlossiness.diffuseTexture) {
                GLTFTextureParams *diffuseTexture = material.specularGlossiness.diffuseTexture;
                SCNMaterialProperty *diffuseProperty = scnMaterial.diffuse;
                diffuseProperty.contents = imagesForIdentfiers[diffuseTexture.texture.source.identifier];
                GLTFConfigureSCNMaterialProperty(diffuseProperty, diffuseTexture);
                // This is pretty awful, but we have no other straightforward way of supporting
                // diffuse textures and factors simultaneously
                simd_float4 rgba = material.specularGlossiness.diffuseFactor;
                CGFloat rgbad[] = { rgba[0], rgba[1], rgba[2], rgba[3] };
                scnMaterial.multiply.contents = (__bridge_transfer id)CGColorCreate(colorSpaceLinearSRGB, rgbad);
            } else {
                SCNMaterialProperty *diffuseProperty = scnMaterial.diffuse;
                simd_float4 rgba = material.specularGlossiness.diffuseFactor;
                CGFloat rgbad[] = { rgba[0], rgba[1], rgba[2], rgba[3] };
                diffuseProperty.contents = (__bridge_transfer id)CGColorCreate(colorSpaceLinearSRGB, rgbad);
            }
            // TODO: Remainder of specular-glossiness model
        }
        if (material.normalTexture) {
            GLTFTextureParams *normalTexture = material.normalTexture;
            SCNMaterialProperty *normalProperty = scnMaterial.normal;
            normalProperty.contents = imagesForIdentfiers[normalTexture.texture.source.identifier];
            GLTFConfigureSCNMaterialProperty(normalProperty, normalTexture);
        }
        if (material.emissiveTexture) {
            GLTFTextureParams *emissiveTexture = material.emissiveTexture;
            SCNMaterialProperty *emissiveProperty = scnMaterial.emission;
            emissiveProperty.contents = imagesForIdentfiers[emissiveTexture.texture.source.identifier];
            GLTFConfigureSCNMaterialProperty(emissiveProperty, emissiveTexture);
        } else {
            SCNMaterialProperty *emissiveProperty = scnMaterial.emission;
            simd_float3 rgb = material.emissiveFactor;
            CGFloat rgbad[] = { rgb[0], rgb[1], rgb[2], 1.0 };
            emissiveProperty.contents = (__bridge_transfer id)CGColorCreate(colorSpaceLinearSRGB, &rgbad[0]);
        }
        if (material.occlusionTexture) {
            GLTFTextureParams *occlusionTexture = material.occlusionTexture;
            SCNMaterialProperty *occlusionProperty = scnMaterial.ambientOcclusion;
            occlusionProperty.contents = imagesForIdentfiers[occlusionTexture.texture.source.identifier];
            GLTFConfigureSCNMaterialProperty(occlusionProperty, occlusionTexture);
        }
        if (material.clearcoat) {
            if (@available(macOS 10.15, *)) {
                if (material.clearcoat.clearcoatTexture) {
                    GLTFTextureParams *clearcoatTexture = material.clearcoat.clearcoatTexture;
                    SCNMaterialProperty *clearcoatProperty = scnMaterial.clearCoat;
                    clearcoatProperty.contents = imagesForIdentfiers[clearcoatTexture.texture.source.identifier];
                    GLTFConfigureSCNMaterialProperty(clearcoatProperty, material.clearcoat.clearcoatTexture);
                } else {
                    scnMaterial.clearCoat.contents = @(material.clearcoat.clearcoatFactor);
                }
                if (material.clearcoat.clearcoatRoughnessTexture) {
                    GLTFTextureParams *clearcoatRoughnessTexture = material.clearcoat.clearcoatRoughnessTexture;
                    SCNMaterialProperty *clearcoatRoughnessProperty = scnMaterial.clearCoatRoughness;
                    clearcoatRoughnessProperty.contents = imagesForIdentfiers[clearcoatRoughnessTexture.texture.source.identifier];
                    GLTFConfigureSCNMaterialProperty(clearcoatRoughnessProperty, material.clearcoat.clearcoatRoughnessTexture);
                } else {
                    scnMaterial.clearCoatRoughness.contents = @(material.clearcoat.clearcoatRoughnessFactor);
                }
                if (material.clearcoat.clearcoatNormalTexture) {
                    GLTFTextureParams *clearcoatNormalTexture = material.clearcoat.clearcoatNormalTexture;
                    SCNMaterialProperty *clearcoatNormalProperty = scnMaterial.clearCoatNormal;
                    clearcoatNormalProperty.contents = imagesForIdentfiers[clearcoatNormalTexture.texture.source.identifier];
                    GLTFConfigureSCNMaterialProperty(clearcoatNormalProperty, material.clearcoat.clearcoatNormalTexture);
                }
            }
        }
        scnMaterial.doubleSided = material.isDoubleSided;
        scnMaterial.blendMode = (material.alphaMode == GLTFAlphaModeBlend) ? SCNBlendModeAlpha : SCNBlendModeReplace;
        scnMaterial.transparencyMode = SCNTransparencyModeDefault;
        // TODO: Use shader modifiers to implement more precise alpha test cutoff?
        materialsForIdentifiers[material.identifier] = scnMaterial;
    }
    
    NSMutableDictionary <NSUUID *, SCNGeometry *> *geometryForIdentifiers = [NSMutableDictionary dictionary];
    NSMutableDictionary <NSUUID *, SCNGeometryElement *> *geometryElementForIdentifiers = [NSMutableDictionary dictionary];
    for (GLTFMesh *mesh in asset.meshes) {
        for (GLTFPrimitive *primitive in mesh.primitives) {
            int vertexCount = 0;
            GLTFAccessor *positionAccessor = primitive.attributes[GLTFAttributeSemanticPosition];
            if (positionAccessor != nil) {
                vertexCount = (int)positionAccessor.count;
            }
            SCNMaterial *material = materialsForIdentifiers[primitive.material.identifier];
            NSData *indexData = nil;
            int indexSize = 1;
            int indexCount = vertexCount; // If we're not indexed (determined below), our "index" count is our vertex count
            if (primitive.indices) {
                GLTFAccessor *indexAccessor = primitive.indices;
                GLTFBufferView *indexBufferView = indexAccessor.bufferView;
                assert(indexBufferView.stride == 0 || indexBufferView.stride == indexSize);
                GLTFBuffer *indexBuffer = indexBufferView.buffer;
                indexCount = (int)primitive.indices.count;
                if((indexAccessor.componentType == GLTFComponentTypeUnsignedShort) ||
                   (indexAccessor.componentType == GLTFComponentTypeUnsignedInt))
                {
                    indexSize = indexAccessor.componentType == GLTFComponentTypeUnsignedInt ? sizeof(UInt32) : sizeof(UInt16);
                    indexData = [NSData dataWithBytesNoCopy:(void *)indexBuffer.data.bytes + indexBufferView.offset + indexAccessor.offset
                                                             length:indexCount * indexSize
                                                       freeWhenDone:NO];
                }
                else
                {
                    assert(indexAccessor.componentType == GLTFComponentTypeUnsignedByte);
                    // We don't directly support 8-bit indices, but converting them is simple enough
                    indexSize = sizeof(UInt16);
                    void *bufferViewBaseAddr = (void *)indexBuffer.data.bytes + indexBufferView.offset;
                    indexData = GLTFPackedUInt16DataFromPackedUInt8(bufferViewBaseAddr + indexAccessor.offset, indexCount);
                }
            }
            SCNGeometryElement *element = GLTFSCNGeometryElementForIndexData(indexData, indexCount, indexSize, primitive);
            geometryElementForIdentifiers[primitive.identifier] = element;

            NSMutableArray *geometrySources = [NSMutableArray arrayWithCapacity:primitive.attributes.count];
            for (NSString *key in primitive.attributes.allKeys) {
                GLTFAccessor *attrAccessor = primitive.attributes[key];
                // TODO: Retopologize geometry source if geometry element's data is `nil`.
                // For primitive types not supported by SceneKit (line loops, line strips, triangle
                // fans), we retopologize the primitive's indices. However, if they aren't present,
                // we need to adjust the vertex data.
                [geometrySources addObject:GLTFSCNGeometrySourceForAccessor(attrAccessor, key)];
            }
            
            SCNGeometry *geometry = [SCNGeometry geometryWithSources:geometrySources elements:@[element]];
            geometry.firstMaterial = material ?: defaultMaterial;
            geometryForIdentifiers[primitive.identifier] = geometry;
        }
    }
    
    NSMutableDictionary<NSUUID *, SCNCamera *> *camerasForIdentifiers = [NSMutableDictionary dictionary];
    for (GLTFCamera *camera in asset.cameras) {
        SCNCamera *scnCamera = [SCNCamera camera];
        scnCamera.name = camera.name;
        if (camera.orthographic) {
            scnCamera.usesOrthographicProjection = YES;
            // This is a lossy transformation.
            scnCamera.orthographicScale = MAX(camera.orthographic.xMag, camera.orthographic.yMag);
        } else {
            scnCamera.usesOrthographicProjection = NO;
            scnCamera.fieldOfView = GLTFDegFromRad(camera.perspective.yFOV);
            scnCamera.projectionDirection = SCNCameraProjectionDirectionVertical;
            // No property for aspect ratio, so we drop it here.
        }
        scnCamera.zNear = camera.zNear;
        scnCamera.zFar = camera.zFar;
        camerasForIdentifiers[camera.identifier] = scnCamera;
    }
    
    NSMutableDictionary<NSUUID *, SCNLight *> *lightsForIdentifiers = [NSMutableDictionary dictionary];
    for (GLTFLight *light in asset.lights) {
        SCNLight *scnLight = [SCNLight light];
        scnLight.name = light.name;
        CGFloat rgba[] = { light.color[0], light.color[1], light.color[2], 1.0 };
        scnLight.color = (__bridge_transfer id)CGColorCreate(colorSpaceLinearSRGB, rgba);
        switch (light.type) {
            case GLTFLightTypeDirectional:
                scnLight.intensity = light.intensity; // TODO: Convert from lux to lumens? How?
                break;
            case GLTFLightTypePoint:
                scnLight.intensity = light.intensity * LumensPerCandela;
                break;
            case GLTFLightTypeSpot:
                scnLight.intensity = light.intensity * LumensPerCandela;
                scnLight.spotInnerAngle = GLTFDegFromRad(light.innerConeAngle);
                scnLight.spotOuterAngle = GLTFDegFromRad(light.outerConeAngle);
                break;
        }
        scnLight.castsShadow = YES;
        lightsForIdentifiers[light.identifier] = scnLight;
    }
    
    NSMutableDictionary<NSUUID *, SCNNode *> *nodesForIdentifiers = [NSMutableDictionary dictionary];
    for (GLTFNode *node in asset.nodes) {
        SCNNode *scnNode = [SCNNode node];
        scnNode.name = node.name;
        scnNode.simdTransform = node.matrix;
        nodesForIdentifiers[node.identifier] = scnNode;
    }

    for (GLTFNode *node in asset.nodes) {
        SCNNode *scnNode = nodesForIdentifiers[node.identifier];
        for (GLTFNode *childNode in node.childNodes) {
            SCNNode *scnChildNode = nodesForIdentifiers[childNode.identifier];
            [scnNode addChildNode:scnChildNode];
        }
    }

    for (GLTFNode *node in asset.nodes) {
        SCNNode *scnNode = nodesForIdentifiers[node.identifier];
        
        if (node.camera) {
            scnNode.camera = camerasForIdentifiers[node.camera.identifier];
        }
        if (node.light) {
            scnNode.light = lightsForIdentifiers[node.light.identifier];
        }

        // This collection holds the nodes to which any skin on this node should be applied,
        // since we don't have a one-to-one mapping from nodes to meshes. It's also used to
        // apply morph targets to the correct primitives.
        NSMutableArray<SCNNode *> *geometryNodes = [NSMutableArray array];

        if (node.mesh) {
            NSArray<GLTFPrimitive *> *primitives = node.mesh.primitives;
            if (primitives.count == 1) {
                [geometryNodes addObject:scnNode];
            } else {
                for (int i = 0; i < primitives.count; ++i) {
                    SCNNode *geometryNode = [SCNNode node];
                    [scnNode addChildNode:geometryNode];
                    [geometryNodes addObject:geometryNode];
                }
            }

            for (int i = 0; i < primitives.count; ++i) {
                GLTFPrimitive *primitive = primitives[i];
                SCNNode *geometryNode = geometryNodes[i];
                geometryNode.geometry = geometryForIdentifiers[primitive.identifier];

                if (primitive.targets.count > 0) {
                    SCNGeometryElement *element = geometryElementForIdentifiers[primitive.identifier];
                    NSMutableArray<SCNGeometry *> *morphGeometries = [NSMutableArray array];
                    for (GLTFMorphTarget *target in primitive.targets) {
                        NSMutableArray<SCNGeometrySource *> *sources = [NSMutableArray array];
                        for (NSString *key in target.allKeys) {
                            GLTFAccessor *targetAccessor = target[key];
                            [sources addObject:GLTFSCNGeometrySourceForAccessor(targetAccessor, key)];
                        }
                        [morphGeometries addObject:[SCNGeometry geometryWithSources:sources
                                                                           elements:@[element]]];
                    }

                    SCNMorpher *scnMorpher = [[SCNMorpher alloc] init];
                    scnMorpher.calculationMode = SCNMorpherCalculationModeAdditive;
                    scnMorpher.targets = morphGeometries;
                    scnMorpher.weights = node.mesh.weights;
                    geometryNode.morpher = scnMorpher;
                }
            }
        }

        if (node.skin) {
            NSMutableArray *bones = [NSMutableArray array];
            for (GLTFNode *jointNode in node.skin.joints) {
                SCNNode *bone = nodesForIdentifiers[jointNode.identifier];
                [bones addObject:bone];
            }
            NSArray *ibmValues = GLTFSCNMatrix4ArrayFromAccessor(node.skin.inverseBindMatrices);
            for (SCNNode *skinnedNode in geometryNodes) {
                SCNGeometrySource *boneWeights = [skinnedNode.geometry geometrySourcesForSemantic:SCNGeometrySourceSemanticBoneWeights].firstObject;
                SCNGeometrySource *boneIndices = [skinnedNode.geometry geometrySourcesForSemantic:SCNGeometrySourceSemanticBoneIndices].firstObject;
                if ((boneIndices.vectorCount != boneWeights.vectorCount) ||
                    ((boneIndices.data.length / boneIndices.vectorCount / boneIndices.bytesPerComponent) !=
                     (boneWeights.data.length / boneWeights.vectorCount / boneWeights.bytesPerComponent))) {
                    // If these conditions fail, we won't be able to create a skinner, so don't bother
                    continue;
                }
                SCNSkinner *skinner = [SCNSkinner skinnerWithBaseGeometry:skinnedNode.geometry
                                                                    bones:bones
                                                boneInverseBindTransforms:ibmValues
                                                              boneWeights:boneWeights
                                                              boneIndices:boneIndices];
                if (node.skin.skeleton) {
                    skinner.skeleton = nodesForIdentifiers[node.skin.skeleton.identifier];
                }
                skinnedNode.skinner = skinner;
            }
        }
    }

    NSMutableDictionary<NSUUID *, GLTFSCNAnimation *> *animationsForIdentifiers = [NSMutableDictionary dictionary];
    for (GLTFAnimation *animation in asset.animations) {
        NSMutableArray *scnChannels = [NSMutableArray array];
        NSTimeInterval maxChannelKeyTime = 0.0;
        for (GLTFAnimationChannel *channel in animation.channels) {
            if (channel.sampler.input.maxValues.count > 0) {
                NSTimeInterval channelMaxTime = channel.sampler.input.maxValues.firstObject.doubleValue;
                if (channelMaxTime > maxChannelKeyTime) {
                    maxChannelKeyTime = channelMaxTime;
                }
            }
        }
        for (GLTFAnimationChannel *channel in animation.channels) {
            CAKeyframeAnimation *caAnimation = nil;
            if ([channel.target.path isEqualToString:GLTFAnimationPathTranslation]) {
                caAnimation = [CAKeyframeAnimation animationWithKeyPath:@"position"];
                caAnimation.values = GLTFSCNVector3ArrayForAccessor(channel.sampler.output);
            } else if ([channel.target.path isEqualToString:GLTFAnimationPathRotation]) {
                caAnimation = [CAKeyframeAnimation animationWithKeyPath:@"orientation"];
                caAnimation.values = GLTFSCNVector4ArrayForAccessor(channel.sampler.output);
            } else if ([channel.target.path isEqualToString:GLTFAnimationPathScale]) {
                caAnimation = [CAKeyframeAnimation animationWithKeyPath:@"scale"];
                caAnimation.values = GLTFSCNVector3ArrayForAccessor(channel.sampler.output);
            } else if ([channel.target.path isEqualToString:GLTFAnimationPathWeights]) {
                // TODO: Weight animations
                continue;
            } else {
                // TODO: This shouldn't be a hard failure, but not sure what to do here yet
                assert(false);
            }
            NSArray<NSNumber *> *baseKeyTimes = GLTFKeyTimeArrayForAccessor(channel.sampler.input, maxChannelKeyTime);
            caAnimation.keyTimes = baseKeyTimes;
            switch (channel.sampler.interpolationMode) {
                case GLTFInterpolationModeLinear:
                    caAnimation.calculationMode = kCAAnimationLinear;
                    break;
                case GLTFInterpolationModeStep:
                    caAnimation.calculationMode = kCAAnimationDiscrete;
                    caAnimation.keyTimes = [@[@(0.0)] arrayByAddingObjectsFromArray:caAnimation.keyTimes];
                    break;
                case GLTFInterpolationModeCubic:
                    caAnimation.calculationMode = kCAAnimationCubic;
                    break;
            }
            caAnimation.beginTime = baseKeyTimes.firstObject.doubleValue;
            caAnimation.duration = maxChannelKeyTime;
            caAnimation.repeatDuration = FLT_MAX;
            GLTFSCNAnimationChannel *clipChannel = [GLTFSCNAnimationChannel new];
            clipChannel.target = nodesForIdentifiers[channel.target.node.identifier];
            SCNAnimation *scnAnimation = [SCNAnimation animationWithCAAnimation:caAnimation];
            clipChannel.animation = scnAnimation;
            [scnChannels addObject:clipChannel];
            
            //[clipChannel.target addAnimation:scnAnimation forKey:channel.target.path]; // HACK for testing
        }
        GLTFSCNAnimation *animationClip = [GLTFSCNAnimation new];
        animationClip.name = animation.name;
        animationClip.channels = scnChannels;
        animationsForIdentifiers[animation.identifier] = animationClip;
    }

    NSMutableDictionary *scenesForIdentifiers = [NSMutableDictionary dictionary];
    for (GLTFScene *scene in asset.scenes) {
        SCNScene *scnScene = [SCNScene scene];
        for (GLTFNode *rootNode in scene.nodes) {
            SCNNode *scnChildNode = nodesForIdentifiers[rootNode.identifier];
            [scnScene.rootNode addChildNode:scnChildNode];
        }
        scenesForIdentifiers[scene.identifier] = scnScene;
    }
    
    CGColorSpaceRelease(colorSpaceLinearSRGB);
    
    if (asset.defaultScene) {
        return scenesForIdentifiers[asset.defaultScene.identifier];
    } else if (asset.scenes.count > 0) {
        return scenesForIdentifiers[asset.scenes.firstObject];
    } else {
        // Last resort. The asset doesn't contain any scenes but we're contractually obligated to return something.
        return [SCNScene scene];
    }
}

@end
