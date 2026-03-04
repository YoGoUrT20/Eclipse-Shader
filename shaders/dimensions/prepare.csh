#include "/lib/settings.glsl"
layout (local_size_x = 1, local_size_y = 1, local_size_z = 1) in;

const ivec3 workGroups = ivec3(1, 1, 1);

#include "/lib/util.glsl"
uniform vec3 cameraPosition;
uniform vec3 relativeEyePosition;

#include "/lib/blocks.glsl"
#include "/lib/entities.glsl"
#include "/lib/lpv_common.glsl"
#include "/lib/lpv_blocks.glsl"
#include "/lib/lpv_buffer.glsl"
#include "/lib/voxel_common.glsl"

uint GetVoxelBlock(const in ivec3 voxelPos) {
    if (clamp(voxelPos, ivec3(0), ivec3(VoxelSize3-1u)) != voxelPos)
        return BLOCK_EMPTY;
    
    return imageLoad(imgVoxelMask, voxelPos).r % 2000u;
}

#include "/lib/SSBOs.glsl"

uniform bool is_sneaking;
uniform float frameTimeCounter;
uniform float frameTime;

#if IRIS_VERSION >= 11004
    uniform bool onWaterSurface;
    uniform int vehicleId;
    uniform bool vehicleInWater;
    uniform bool feetInWater;
    uniform vec3 relativeVehiclePosition;
    uniform bool isRiding;
#endif

vec2 getPlayerMovementOffset() {
    vec2 currentPos = cameraPosition.xz;

    #if IRIS_VERSION >= 11004
    if(isRiding) {
        currentPos -= relativeVehiclePosition.xz;
    } else
    #endif
    {
        currentPos -= relativeEyePosition.xz;
    }

    vec2 previousPos = previousCameraPositionWave2.xz;
    vec2 movement = currentPos - previousPos;
    #if WATER_SIM_SCALE == 0
        return -20.0 * movement;
    #else
        return -40.0 * movement * WATER_SIM_SCALE;
    #endif
}

void main() {
    #if WATER_INTERACTION == 2
    if (abs(frameTimeCounter - lastFrameTimeCount) > WATER_SIM_FRAMETIME) {
        noSimOngoing = noSimOngoingCheck;
        noSimOngoingCheck = true;

        #if IRIS_VERSION >= 11004
            bool inBoat = vehicleId == ENTITY_BOAT;

            bool inShip = false;

            // --- Dropped item water contact detection ---
            // Step 1: Find a dropped item in the voxel grid
            bool foundItem = false;
            int foundDx = 0;
            int foundDy = 0;
            int foundDz = 0;
            {
                #if !defined IS_LPV_ENABLED && !defined SHADER_GRASS
                    vec3 rayStart = vec3(0.0);
                #else
                    vec3 rayStart = vec3(-relativeEyePosition);
                #endif
                vec3 LPVpos = GetLpvPosition(rayStart);

                for (int dx = -2; dx <= 2 && !foundItem; dx++) {
                    for (int dz = -2; dz <= 2 && !foundItem; dz++) {
                        for (int dy = 1; dy >= -2 && !foundItem; dy--) {
                            uint blockID = GetVoxelBlock(ivec3(LPVpos.x + float(dx), LPVpos.y + float(dy), LPVpos.z + float(dz)));
                            if (blockID == ENTITY_ITEM_DROPPED) {
                                foundItem = true;
                                foundDx = dx;
                                foundDy = dy;
                                foundDz = dz;
                            }
                        }
                    }
                }

                // Step 2: If item found, check if it's adjacent to water
                bool itemTouchingWater = false;
                if (foundItem) {
                    ivec3 itemPos = ivec3(LPVpos.x + float(foundDx), LPVpos.y + float(foundDy), LPVpos.z + float(foundDz));
                    // Check the 6 face-adjacent voxels for water
                    if (GetVoxelBlock(itemPos + ivec3( 1, 0, 0)) == BLOCK_WATER) itemTouchingWater = true;
                    if (GetVoxelBlock(itemPos + ivec3(-1, 0, 0)) == BLOCK_WATER) itemTouchingWater = true;
                    if (GetVoxelBlock(itemPos + ivec3( 0, 1, 0)) == BLOCK_WATER) itemTouchingWater = true;
                    if (GetVoxelBlock(itemPos + ivec3( 0,-1, 0)) == BLOCK_WATER) itemTouchingWater = true;
                    if (GetVoxelBlock(itemPos + ivec3( 0, 0, 1)) == BLOCK_WATER) itemTouchingWater = true;
                    if (GetVoxelBlock(itemPos + ivec3( 0, 0,-1)) == BLOCK_WATER) itemTouchingWater = true;
                }

                // Step 3: Edge detection — only splash on the frame the item FIRST touches water
                bool prevTouching = droppedItemPrevFrameSSBO > 0.5;
                droppedItemPrevFrameSSBO = itemTouchingWater ? 1.0 : 0.0;

                // Rising edge: was NOT touching, now IS touching
                bool droppedItemSplash = itemTouchingWater && !prevTouching;

                // Store for prepare1/prepare2
                droppedItemNearWaterSSBO = droppedItemSplash ? 1.0 : 0.0;
                if (droppedItemSplash) {
                    #if WATER_SIM_SCALE == 0
                        float pixelsPerBlock = 20.0;
                    #else
                        float pixelsPerBlock = 40.0 * float(WATER_SIM_SCALE);
                    #endif
                    // Use exact entity position from shadow pass (stored in droppedItemOffsetX/Z)
                    // These values are the entity's player-space XZ coordinates written by voxel_write.glsl
                    float exactEntityX = droppedItemOffsetX;
                    float exactEntityZ = droppedItemOffsetZ;
                    // Convert player-space position to pixel offset for the wave sim texture
                    droppedItemOffsetX = exactEntityX * pixelsPerBlock;
                    droppedItemOffsetZ = exactEntityZ * pixelsPerBlock;
                } else {
                    droppedItemOffsetX = 0.0;
                    droppedItemOffsetZ = 0.0;
                }
            }

            // Use local variable since onWaterSurface is a uniform (read-only)
            bool droppedItemInWater = droppedItemNearWaterSSBO > 0.5;
            bool isOnWaterSurface = onWaterSurface || droppedItemInWater;
        #else
            float playerTallness = 1.5;
            if(is_sneaking) playerTallness = 1.2;
            #if !defined IS_LPV_ENABLED && !defined SHADER_GRASS
                vec3 rayStart = vec3(0.0);
            #else
                vec3 rayStart = vec3(-relativeEyePosition);
            #endif
            vec3 LPVpos = GetLpvPosition(rayStart);
            uint BlockID1 = GetVoxelBlock(ivec3(LPVpos));
            uint BlockID2 = GetVoxelBlock(ivec3(LPVpos.x, LPVpos.y - 0.5*playerTallness, LPVpos.z));
            uint BlockID3 = GetVoxelBlock(ivec3(LPVpos.x, LPVpos.y - playerTallness, LPVpos.z));

            // Big shenanigans lol, don't ask, it just works
            bool inShip = false;
            bool isOnWaterSurface = false;
            bool inBoat = false;
            bool inBoat2Frames = inBoatLastFrame;
            inBoatLastFrame = inBoatCurrentFrame;
            inBoatCurrentFrame = false;

            bool inShip2Frames = inShipLastFrame;
            inShipLastFrame = inShipCurrentFrame;
            inShipCurrentFrame = false;

            if(BlockID1 == BLOCK_WATER || BlockID2 == BLOCK_WATER || BlockID3 == BLOCK_WATER) isOnWaterSurface = true;

            if(BlockID1 == ENTITY_BOAT || BlockID2 == ENTITY_BOAT || BlockID3 == ENTITY_BOAT) inBoatCurrentFrame = true;

            if(BlockID1 == ENTITY_SMALLSHIPS || BlockID2 == ENTITY_SMALLSHIPS || BlockID3 == ENTITY_SMALLSHIPS) inShipCurrentFrame = true;

            if(inBoatCurrentFrame || inBoatLastFrame || inBoat2Frames) inBoat = true;

            if(inShipCurrentFrame || inShipLastFrame || inShip2Frames) inShip = true;

            // Also detect dropped items in water on legacy path
            if(BlockID1 == ENTITY_ITEM_DROPPED || BlockID2 == ENTITY_ITEM_DROPPED || BlockID3 == ENTITY_ITEM_DROPPED) isOnWaterSurface = true;
        #endif

        vec2 playerMovement = getPlayerMovementOffset();
        water_move_compensation_counter_SSBO += playerMovement;

        water_move_compensationSSBO = ivec2(0);
        ivec2 offset = ivec2(trunc(water_move_compensation_counter_SSBO));
        if (any(notEqual(offset, ivec2(0)))) {
            water_move_compensationSSBO = offset;
            water_move_compensation_counter_SSBO -= vec2(offset);
        }

        if (isOnWaterSurface) {
            vec3 position = cameraPosition-previousCameraPositionWave;
            #if IRIS_VERSION >= 11004
            if(isRiding) {
                position -= relativeVehiclePosition;
            } else
            #endif
            {
                position -= relativeEyePosition;
            }
            
            vec3 velocity = position/frameTime;
            velocity.y *= 1.2;
            float speed = length(velocity);

            float size = 10.0;
            #if IRIS_VERSION >= 11004
                if(droppedItemInWater && !feetInWater && !vehicleInWater) {
                    // Dropped items make small, constant ripples
                    size = 5.0;
                } else if(inBoat) {
                    size += 23.0;
                } else if (inShip) {
                    size += 61.0 * smoothstep(0.0, 10.0, speed);
                } else {
                    size += 10.0 * smoothstep(0.1, 13.0, speed);
                }
            #else
                if(inBoat) {
                    size += 26.0 * smoothstep(0.0, 10.0, speed);
                } else if (inShip) {
                    size += 61.0 * smoothstep(0.0, 10.0, speed);
                } else {
                    size += 10.0 * smoothstep(0.1, 13.0, speed);
                }
            #endif

            #if WATER_SIM_SCALE == 0
                size *= 0.5;
            #else
                size *= WATER_SIM_SCALE;
            #endif

            #if IRIS_VERSION >= 11004
            if(speed < 0.15 && isRiding) size = 0.01;
            #endif

            waterRoundSize = size;
        }
    }
    #endif
}