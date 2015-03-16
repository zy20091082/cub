
/******************************************************************************
 * Copyright (c) 2011, Duane Merrill.  All rights reserved.
 * Copyright (c) 2011-2014, NVIDIA CORPORATION.  All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *     * Redistributions of source code must retain the above copyright
 *       notice, this list of conditions and the following disclaimer.
 *     * Redistributions in binary form must reproduce the above copyright
 *       notice, this list of conditions and the following disclaimer in the
 *       documentation and/or other materials provided with the distribution.
 *     * Neither the name of the NVIDIA CORPORATION nor the
 *       names of its contributors may be used to endorse or promote products
 *       derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL NVIDIA CORPORATION BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 ******************************************************************************/

/**
 * \file
 * cub::DeviceSpmv provides device-wide parallel operations for performing sparse-matrix * vector multiplication (SpMV).
 */

#pragma once

#include <stdio.h>
#include <iterator>
#include <limits>

#include "dispatch_reduce_by_key.cuh"
#include "../../agent/agent_spmv.cuh"
#include "../../util_type.cuh"
#include "../../util_debug.cuh"
#include "../../util_device.cuh"
#include "../../thread/thread_search.cuh"
#include "../../grid/grid_queue.cuh"
#include "../../util_namespace.cuh"

/// Optional outer namespace(s)
CUB_NS_PREFIX

/// CUB namespace
namespace cub {


/******************************************************************************
 * SpMV kernel entry points
 *****************************************************************************/

/**
 * Spmv search kernel. Identifies merge path starting coordinates for each tile.
 */
template <
    typename    SpmvPolicyTT,                   ///< Parameterized SpmvPolicyT tuning policy type
    typename    ScanTileStateT,                     ///< Tile status interface type
    typename    OffsetT,                            ///< Signed integer type for sequence offsets
    typename    CoordinateT>                        ///< Merge path coordinate type
__global__ void DeviceSpmvSearchKernel(
    ScanTileStateT  tile_state,                     ///< [in] Tile status interface
    int             num_spmv_tiles,
    int             num_reduce_by_key_tiles,
    OffsetT*        d_matrix_row_end_offsets,       ///< [in] Pointer to the array of \p m offsets demarcating the end of every row in \p d_matrix_column_indices and \p d_matrix_values
    CoordinateT*    d_tile_coordinates,             ///< [out] Pointer to the temporary array of tile starting coordinates
    int             num_rows,                       ///< [in] number of rows of matrix <b>A</b>.
    int             num_nonzeros)                   ///< [in] number of nonzero elements of matrix <b>A</b>.
{
    /// Constants
    enum
    {
        BLOCK_THREADS           = SpmvPolicyTT::BLOCK_THREADS,
        ITEMS_PER_THREAD        = SpmvPolicyTT::ITEMS_PER_THREAD,
        TILE_ITEMS              = BLOCK_THREADS * ITEMS_PER_THREAD,
    };

    typedef CacheModifiedInputIterator<
            SpmvPolicyTT::MATRIX_ROW_OFFSETS_LOAD_MODIFIER,
            OffsetT,
            OffsetT>
        MatrixRowOffsetsIteratorT;

    // Initialize tile status
    tile_state.InitializeStatus(num_reduce_by_key_tiles);

    // Find the starting coordinate for all tiles (plus the end coordinate of the last one)
    int tile_idx = (blockIdx.x * blockDim.x) + threadIdx.x;
    if (tile_idx < num_spmv_tiles + 1)
    {
        OffsetT                         diagonal = (tile_idx * TILE_ITEMS);
        CoordinateT                     tile_coordinate;
        CountingInputIterator<OffsetT>  nonzero_indices(0);

        // Search the merge path
        MergePathSearch(
            diagonal,
            MatrixRowOffsetsIteratorT(d_matrix_row_end_offsets),
            nonzero_indices,
            num_rows,
            num_nonzeros,
            tile_coordinate);

        // Output starting offset
        d_tile_coordinates[tile_idx] = tile_coordinate;
    }
}


/**
 * Spmv agent entry point
 */
template <
    typename        SpmvPolicyTT,           ///< Parameterized SpmvPolicyT tuning policy type
    typename        ValueT,                     ///< Matrix and vector value type
    typename        OffsetT,                    ///< Signed integer type for sequence offsets
    typename        CoordinateT>                ///< Merge path coordinate type
__launch_bounds__ (int(SpmvPolicyTT::BLOCK_THREADS))
__global__ void DeviceSpmvKernel(
    ValueT*         d_matrix_values,            ///< [in] Pointer to the array of \p num_nonzeros values of the corresponding nonzero elements of matrix <b>A</b>.
    OffsetT*        d_matrix_row_end_offsets,   ///< [in] Pointer to the array of \p m offsets demarcating the end of every row in \p d_matrix_column_indices and \p d_matrix_values
    OffsetT*        d_matrix_column_indices,    ///< [in] Pointer to the array of \p num_nonzeros column-indices of the corresponding nonzero elements of matrix <b>A</b>.  (Indices are zero-valued.)
    ValueT*         d_vector_x,                 ///< [in] Pointer to the array of \p num_cols values corresponding to the dense input vector <em>x</em>
    ValueT*         d_vector_y,                 ///< [out] Pointer to the array of \p num_rows values corresponding to the dense output vector <em>y</em>
    CoordinateT*    d_tile_coordinates,         ///< [in] Pointer to the temporary array of tile starting coordinates
    OffsetT*        d_tile_carry_rows,          ///< [out] Pointer to the temporary array carry-out dot product row-ids, one per block
    ValueT*         d_tile_carry_values,        ///< [out] Pointer to the temporary array carry-out dot product partial-sums, one per block
    int             num_rows,                   ///< [in] number of rows of matrix <b>A</b>.
    int             num_cols,                   ///< [in] number of columns of matrix <b>A</b>.
    int             num_nonzeros)               ///< [in] number of nonzero elements of matrix <b>A</b>.
{
    // Spmv agent type specialization
    typedef AgentSpmv<
            SpmvPolicyTT,
            ValueT,
            OffsetT,
            CoordinateT>
        AgentSpmvT;

    // Shared memory for AgentSpmv
    __shared__ typename AgentSpmvT::TempStorage temp_storage;

    AgentSpmvT agent(
        temp_storage,
        d_matrix_values,
        d_matrix_row_end_offsets,
        d_matrix_column_indices,
        d_vector_x,
        d_vector_y,
        d_tile_carry_rows,
        d_tile_carry_values,
        num_rows,
        num_cols,
        num_nonzeros);

    agent.ConsumeTile(d_tile_coordinates);
}



/******************************************************************************
 * Dispatch
 ******************************************************************************/

/**
 * Utility class for dispatching the appropriately-tuned kernels for DeviceSpmv
 */
template <
    typename    ValueT,                     ///< Matrix and vector value type
    typename    OffsetT>                    ///< Signed integer type for global offsets
struct DispatchSpmv
{
    //---------------------------------------------------------------------
    // Constants and Types
    //---------------------------------------------------------------------

    enum
    {
        INIT_KERNEL_THREADS = 128
    };

    // 2D merge path coordinate type
    typedef typename CubVector<OffsetT, 2>::Type CoordinateT;

    // Reduce-by-key fixup dispatch type
    typedef DispatchReduceByKey<OffsetT*, OffsetT*, ValueT*, ValueT*, OffsetT*, cub::Equality, cub::Sum, OffsetT>
        DispatchReduceByKeyT;

    // Reduce-by-key tile status descriptor interface type
    typedef typename DispatchReduceByKeyT::ScanTileStateT ScanTileStateT;


    //---------------------------------------------------------------------
    // Tuning policies
    //---------------------------------------------------------------------

    /// SM11
    struct Policy110 : DispatchReduceByKeyT::Policy110
    {
        typedef AgentSpmvPolicy<
                128,
                1,
                LOAD_DEFAULT,
                LOAD_DEFAULT,
                LOAD_DEFAULT,
                LOAD_DEFAULT,
                false,
                BLOCK_SCAN_WARP_SCANS>
            SpmvPolicyT;
    };

    /// SM20
    struct Policy200 : Policy110 {};

    /// SM30
    struct Policy300 : DispatchReduceByKeyT::Policy300
    {
        typedef AgentSpmvPolicy<
                128,
                7,
                LOAD_DEFAULT,
                LOAD_DEFAULT,
                LOAD_DEFAULT,
                LOAD_DEFAULT,
                false,
                BLOCK_SCAN_WARP_SCANS>
            SpmvPolicyT;
    };

    /// SM35
    struct Policy350 : DispatchReduceByKeyT::Policy350
    {
        typedef AgentSpmvPolicy<
                128,
                7,
                LOAD_LDG,
                LOAD_LDG,
                LOAD_LDG,
                LOAD_LDG,
                true,
                BLOCK_SCAN_WARP_SCANS>
            SpmvPolicyT;
    };

    /// SM50
    struct Policy500 : DispatchReduceByKeyT::Policy350
    {
        typedef AgentSpmvPolicy<
                (sizeof(ValueT) > 4) ? 64 : 128,
                7,
                LOAD_LDG,
                LOAD_LDG,
                LOAD_LDG,
                LOAD_LDG,
                false,
                (sizeof(ValueT) > 4) ? BLOCK_SCAN_WARP_SCANS : BLOCK_SCAN_RAKING_MEMOIZE>
            SpmvPolicyT;
    };



    //---------------------------------------------------------------------
    // Tuning policies of current PTX compiler pass
    //---------------------------------------------------------------------

#if (CUB_PTX_ARCH >= 500)
    typedef Policy500 PtxPolicy;

#elif (CUB_PTX_ARCH >= 350)
    typedef Policy350 PtxPolicy;

#elif (CUB_PTX_ARCH >= 300)
    typedef Policy300 PtxPolicy;

#elif (CUB_PTX_ARCH >= 200)
    typedef Policy200 PtxPolicy;

#else
    typedef Policy110 PtxPolicy;

#endif

    // "Opaque" policies (whose parameterizations aren't reflected in the type signature)
    struct PtxSpmvPolicyT : PtxPolicy::SpmvPolicyT {};
    struct PtxReduceByKeyPolicy : PtxPolicy::ReduceByKeyPolicyT {};


    //---------------------------------------------------------------------
    // Utilities
    //---------------------------------------------------------------------

    /**
     * Initialize kernel dispatch configurations with the policies corresponding to the PTX assembly we will use
     */
    template <typename KernelConfig>
    CUB_RUNTIME_FUNCTION __forceinline__
    static void InitConfigs(
        int             ptx_version,
        KernelConfig    &spmv_config,
        KernelConfig    &reduce_by_key_config)
    {
    #if (CUB_PTX_ARCH > 0)

        // We're on the device, so initialize the kernel dispatch configurations with the current PTX policy
        spmv_config.template Init<PtxSpmvPolicyT>();
        reduce_by_key_config.template Init<PtxReduceByKeyPolicy>();

    #else

        // We're on the host, so lookup and initialize the kernel dispatch configurations with the policies that match the device's PTX version
        if (ptx_version >= 500)
        {
            spmv_config.template Init<typename Policy500::SpmvPolicyT>();
        }
        else if (ptx_version >= 350)
        {
            spmv_config.template            Init<typename Policy350::SpmvPolicyT>();
            reduce_by_key_config.template   Init<typename Policy350::ReduceByKeyPolicyT>();
        }
        else if (ptx_version >= 300)
        {
            spmv_config.template            Init<typename Policy300::SpmvPolicyT>();
            reduce_by_key_config.template   Init<typename Policy300::ReduceByKeyPolicyT>();

        }
        else if (ptx_version >= 200)
        {
            spmv_config.template            Init<typename Policy200::SpmvPolicyT>();
            reduce_by_key_config.template   Init<typename Policy200::ReduceByKeyPolicyT>();
        }
        else
        {
            spmv_config.template            Init<typename Policy110::SpmvPolicyT>();
            reduce_by_key_config.template   Init<typename Policy110::ReduceByKeyPolicyT>();
        }

    #endif
    }


    /**
     * Kernel kernel dispatch configuration.
     */
    struct KernelConfig
    {
        int block_threads;
        int items_per_thread;
        int tile_items;

        template <typename PolicyT>
        CUB_RUNTIME_FUNCTION __forceinline__
        void Init()
        {
            block_threads       = PolicyT::BLOCK_THREADS;
            items_per_thread    = PolicyT::ITEMS_PER_THREAD;
            tile_items          = block_threads * items_per_thread;
        }
    };


    //---------------------------------------------------------------------
    // Dispatch entrypoints
    //---------------------------------------------------------------------

    /**
     * Internal dispatch routine for computing a device-wide reduction using the
     * specified kernel functions.
     *
     * If the input is larger than a single tile, this method uses two-passes of
     * kernel invocations.
     */
    template <
        typename                SpmvSearchKernelT,                  ///< Function type of cub::AgentSpmvSearchKernel
        typename                SpmvKernelT,                        ///< Function type of cub::AgentSpmvKernel
        typename                ReduceByKeyKernelT>                 ///< Function type of cub::DeviceReduceByKeyKernelT
    CUB_RUNTIME_FUNCTION __forceinline__
    static cudaError_t Dispatch(
        void*                   d_temp_storage,                     ///< [in] %Device allocation of temporary storage.  When NULL, the required allocation size is written to \p temp_storage_bytes and no work is done.
        size_t&                 temp_storage_bytes,                 ///< [in,out] Reference to size in bytes of \p d_temp_storage allocation
        ValueT*                 d_matrix_values,                    ///< [in] Pointer to the array of \p num_nonzeros values of the corresponding nonzero elements of matrix <b>A</b>.
        OffsetT*                d_matrix_row_offsets,               ///< [in] Pointer to the array of \p m + 1 offsets demarcating the start of every row in \p d_matrix_column_indices and \p d_matrix_values (with the final entry being equal to \p num_nonzeros)
        OffsetT*                d_matrix_column_indices,            ///< [in] Pointer to the array of \p num_nonzeros column-indices of the corresponding nonzero elements of matrix <b>A</b>.  (Indices are zero-valued.)
        ValueT*                 d_vector_x,                         ///< [in] Pointer to the array of \p num_cols values corresponding to the dense input vector <em>x</em>
        ValueT*                 d_vector_y,                         ///< [out] Pointer to the array of \p num_rows values corresponding to the dense output vector <em>y</em>
        int                     num_rows,                           ///< [in] number of rows of matrix <b>A</b>.
        int                     num_cols,                           ///< [in] number of columns of matrix <b>A</b>.
        int                     num_nonzeros,                       ///< [in] number of nonzero elements of matrix <b>A</b>.
        cudaStream_t            stream,                             ///< [in] CUDA stream to launch kernels within.  Default is stream<sub>0</sub>.
        bool                    debug_synchronous,                  ///< [in] Whether or not to synchronize the stream after every kernel launch to check for errors.  Also causes launch configurations to be printed to the console.  Default is \p false.
        SpmvSearchKernelT       spmv_search_kernel,                 ///< [in] Kernel function pointer to parameterization of AgentSpmvSearchKernel
        SpmvKernelT             spmv_kernel,                        ///< [in] Kernel function pointer to parameterization of AgentSpmvKernel
        ReduceByKeyKernelT      reduce_by_key_kernel,               ///< [in] Kernel function pointer to parameterization of cub::DeviceReduceByKeyKernel
        KernelConfig            spmv_config,                        ///< [in] Dispatch parameters that match the policy that \p spmv_kernel was compiled for
        KernelConfig            reduce_by_key_config)               ///< [in] Dispatch parameters that match the policy that \p reduce_by_key_kernel was compiled for
    {
#ifndef CUB_RUNTIME_ENABLED

        // Kernel launch not supported from this device
        return CubDebug(cudaErrorNotSupported );

#else
        cudaError error = cudaSuccess;
        do
        {
            // Row end offsets
            OffsetT* d_matrix_row_end_offsets = d_matrix_row_offsets + 1;

            // Get device ordinal
            int device_ordinal;
            if (CubDebug(error = cudaGetDevice(&device_ordinal))) break;

            // Get device SM version
            int sm_version;
            if (CubDebug(error = SmVersion(sm_version, device_ordinal))) break;

            // Get SM count
            int sm_count;
            if (CubDebug(error = cudaDeviceGetAttribute (&sm_count, cudaDevAttrMultiProcessorCount, device_ordinal))) break;

            // Get max x-dimension of grid
            int max_dim_x;
            if (CubDebug(error = cudaDeviceGetAttribute(&max_dim_x, cudaDevAttrMaxGridDimX, device_ordinal))) break;;

            // Total number of spmv work items
            int num_spmv_items = num_rows + num_nonzeros;

            // Tile sizes of kernels
            int spmv_tile_size              = spmv_config.block_threads * spmv_config.items_per_thread;
            int reduce_by_key_tile_size     = reduce_by_key_config.block_threads * reduce_by_key_config.items_per_thread;

            // Number of tiles for kernels
            unsigned int num_spmv_tiles             = (num_spmv_items + spmv_tile_size - 1) / spmv_tile_size;
            unsigned int num_reduce_by_key_tiles    = (num_spmv_tiles + reduce_by_key_tile_size - 1) / reduce_by_key_tile_size;

            // Get SM occupancy for kernels
            int spmv_sm_occupancy;
            if (CubDebug(error = MaxSmOccupancy(
                spmv_sm_occupancy,
                sm_version,
                spmv_kernel,
                spmv_config.block_threads))) break;

            int reduce_by_key_sm_occupancy;
            if (CubDebug(error = MaxSmOccupancy(
                reduce_by_key_sm_occupancy,
                sm_version,
                reduce_by_key_kernel,
                reduce_by_key_config.block_threads))) break;

            // Get grid dimensions
            dim3 spmv_grid_size(
                CUB_MIN(num_spmv_tiles, max_dim_x),
                (num_spmv_tiles + max_dim_x - 1) / max_dim_x,
                1);

            dim3 reduce_by_key_grid_size(
                CUB_MIN(num_reduce_by_key_tiles, max_dim_x),
                (num_reduce_by_key_tiles + max_dim_x - 1) / max_dim_x,
                1);

            // Get the temporary storage allocation requirements
            size_t allocation_sizes[4];
            if (CubDebug(error = ScanTileStateT::AllocationSize(num_reduce_by_key_tiles, allocation_sizes[0]))) break;    // bytes needed for reduce-by-key tile status descriptors
            allocation_sizes[1] = num_spmv_tiles * sizeof(OffsetT);             // bytes needed for block run-out row-ids
            allocation_sizes[2] = num_spmv_tiles * sizeof(ValueT);              // bytes needed for block run-out partials sums
            allocation_sizes[3] = (num_spmv_tiles + 1) * sizeof(CoordinateT);   // bytes needed for tile starting coordinates

            // Alias the temporary allocations from the single storage blob (or compute the necessary size of the blob)
            void* allocations[4];
            if (CubDebug(error = AliasTemporaries(d_temp_storage, temp_storage_bytes, allocations, allocation_sizes))) break;
            if (d_temp_storage == NULL)
            {
                // Return if the caller is simply requesting the size of the storage allocation
                return cudaSuccess;
            }

            // Construct the tile status interface
            ScanTileStateT tile_state;
            if (CubDebug(error = tile_state.Init(num_reduce_by_key_tiles, allocations[0], allocation_sizes[0]))) break;

            // Alias the other allocations
            OffsetT*        d_tile_carry_rows       = (OffsetT*) allocations[1];        // Agent carry-out row-ids
            ValueT*         d_tile_carry_values     = (ValueT*) allocations[2];         // Agent carry-out partial sums
            CoordinateT*    d_tile_coordinates      = (CoordinateT*) allocations[3];    // Agent starting coordinates

            // Get search/init grid dims
            int search_block_size   = INIT_KERNEL_THREADS;
            int search_grid_size    = (num_spmv_tiles + 1 + search_block_size - 1) / search_block_size;

            // Log spmv_search_kernel configuration
            if (debug_synchronous) CubLog("Invoking spmv_search_kernel<<<%d, %d, 0, %lld>>>()\n",
                search_grid_size, search_block_size, (long long) stream);

            // Invoke spmv_search_kernel
            spmv_search_kernel<<<search_grid_size, search_block_size, 0, stream>>>(
                tile_state,
                num_spmv_tiles,
                num_reduce_by_key_tiles,
                d_matrix_row_end_offsets,
                d_tile_coordinates,
                num_rows,
                num_nonzeros);

            // Log spmv_kernel configuration
            if (debug_synchronous) CubLog("Invoking spmv_kernel<<<{%d,%d,%d}, %d, 0, %lld>>>(), %d items per thread, %d SM occupancy\n",
                spmv_grid_size.x, spmv_grid_size.y, spmv_grid_size.z, spmv_config.block_threads, (long long) stream, spmv_config.items_per_thread, spmv_sm_occupancy);

            // Invoke spmv_kernel
            spmv_kernel<<<spmv_grid_size, spmv_config.block_threads, 0, stream>>>(
                d_matrix_values,
                d_matrix_row_end_offsets,
                d_matrix_column_indices,
                d_vector_x,
                d_vector_y,
                d_tile_coordinates,
                d_tile_carry_rows,
                d_tile_carry_values,
                num_rows,
                num_cols,
                num_nonzeros);

            // Check for failure to launch
            if (CubDebug(error = cudaPeekAtLastError())) break;

            // Sync the stream if specified to flush runtime errors
            if (debug_synchronous && (CubDebug(error = SyncStream(stream)))) break;

            // Run reduce-by-key fixup if necessary
            if (num_spmv_tiles > 1)
            {
                // Log reduce_by_key_kernel configuration
                if (debug_synchronous) CubLog("Invoking reduce_by_key_kernel<<<{%d,%d,%d}, %d, 0, %lld>>>(), %d items per thread, %d SM occupancy\n",
                    reduce_by_key_grid_size.x, reduce_by_key_grid_size.y, reduce_by_key_grid_size.z, reduce_by_key_config.block_threads, (long long) stream, reduce_by_key_config.items_per_thread, reduce_by_key_sm_occupancy);

                // Invoke reduce_by_key_kernel
                reduce_by_key_kernel<<<reduce_by_key_grid_size, reduce_by_key_config.block_threads, 0, stream>>>(
                    d_tile_carry_rows,
                    NULL,
                    d_tile_carry_values,
                    d_vector_y,
                    NULL,
                    tile_state,
                    cub::Equality(),
                    cub::Sum(),
                    num_spmv_tiles,
                    num_reduce_by_key_tiles);

                // Check for failure to launch
                if (CubDebug(error = cudaPeekAtLastError())) break;

                // Sync the stream if specified to flush runtime errors
                if (debug_synchronous && (CubDebug(error = SyncStream(stream)))) break;
            }
        }
        while (0);

        return error;

#endif // CUB_RUNTIME_ENABLED
    }


    /**
     * Internal dispatch routine for computing a device-wide reduction
     */
    CUB_RUNTIME_FUNCTION __forceinline__
    static cudaError_t Dispatch(
        void*               d_temp_storage,                     ///< [in] %Device allocation of temporary storage.  When NULL, the required allocation size is written to \p temp_storage_bytes and no work is done.
        size_t&             temp_storage_bytes,                 ///< [in,out] Reference to size in bytes of \p d_temp_storage allocation
        ValueT*             d_matrix_values,                    ///< [in] Pointer to the array of \p num_nonzeros values of the corresponding nonzero elements of matrix <b>A</b>.
        OffsetT*            d_matrix_row_offsets,               ///< [in] Pointer to the array of \p m + 1 offsets demarcating the start of every row in \p d_matrix_column_indices and \p d_matrix_values (with the final entry being equal to \p num_nonzeros)
        OffsetT*            d_matrix_column_indices,            ///< [in] Pointer to the array of \p num_nonzeros column-indices of the corresponding nonzero elements of matrix <b>A</b>.  (Indices are zero-valued.)
        ValueT*             d_vector_x,                         ///< [in] Pointer to the array of \p num_cols values corresponding to the dense input vector <em>x</em>
        ValueT*             d_vector_y,                         ///< [out] Pointer to the array of \p num_rows values corresponding to the dense output vector <em>y</em>
        int                 num_rows,                           ///< [in] number of rows of matrix <b>A</b>.
        int                 num_cols,                           ///< [in] number of columns of matrix <b>A</b>.
        int                 num_nonzeros,                       ///< [in] number of nonzero elements of matrix <b>A</b>.
        cudaStream_t        stream                  = 0,        ///< [in] <b>[optional]</b> CUDA stream to launch kernels within.  Default is stream<sub>0</sub>.
        bool                debug_synchronous       = false)    ///< [in] <b>[optional]</b> Whether or not to synchronize the stream after every kernel launch to check for errors.  May cause significant slowdown.  Default is \p false.
    {
        cudaError error = cudaSuccess;
        do
        {
            // Get PTX version
            int ptx_version;
    #if (CUB_PTX_ARCH == 0)
            if (CubDebug(error = PtxVersion(ptx_version))) break;
    #else
            ptx_version = CUB_PTX_ARCH;
    #endif

            // Get kernel kernel dispatch configurations
            KernelConfig spmv_config, reduce_by_key_config;
            InitConfigs(ptx_version, spmv_config, reduce_by_key_config);

            // Dispatch
            if (CubDebug(error = Dispatch(
                d_temp_storage,
                temp_storage_bytes,
                d_matrix_values,
                d_matrix_row_offsets,
                d_matrix_column_indices,
                d_vector_x,
                d_vector_y,
                num_rows,
                num_cols,
                num_nonzeros,
                stream,
                debug_synchronous,
                DeviceSpmvSearchKernel<PtxSpmvPolicyT, ScanTileStateT, OffsetT, CoordinateT>,
                DeviceSpmvKernel<PtxSpmvPolicyT, ValueT, OffsetT, CoordinateT>,
                DeviceReduceByKeyKernel<PtxReduceByKeyPolicy, OffsetT*, OffsetT*, ValueT*, ValueT*, OffsetT*, ScanTileStateT, cub::Equality, cub::Sum, OffsetT, true>,
                spmv_config,
                reduce_by_key_config))) break;
        }
        while (0);

        return error;
    }
};


}               // CUB namespace
CUB_NS_POSTFIX  // Optional outer namespace(s)


