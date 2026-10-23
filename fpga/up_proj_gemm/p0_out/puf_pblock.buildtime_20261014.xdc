#=============================================================================
# puf_pblock.buildtime_20261014.xdc
#
# BUILD-TIME SNAPSHOT -- the exact puf_pblock region the ACCEPTED frozen
# bitstream was built with:
#   impl_1, 2026-10-14 20:31:47, up_proj_wrapper.bit
#   SHA256 6235148F1912C06DEC14E2BAAE211D4634609997C71C995FCABF917EC40BBEDE
#
# Provenance:
#   p0_out/puf_lock_20261014c.log line 149 printed
#     "== puf_lock pblock region : SLICE_X22Y240:SLICE_X51Y271"
#   and tools/add_puf_to_bd.tcl (run 19:44) registered that file into constrs_1.
#
# NOTE: the WORKING file constr/puf_pblock.xdc was regenerated to
#   SLICE_X23Y240:SLICE_X50Y271 by the freeze-verification re-run (20:47)
#   (bbox drift: the generator's bbox covers ALL 4883 leaves under u_array,
#   including un-pinned control logic such as the majority-vote counters).
#   The PUF fingerprint is unaffected either way -- it is fixed by the
#   256 LOC+BEL pins in constr/puf_loc_generated.tcl, not by this region.
#=============================================================================

create_pblock pb_bpuf
resize_pblock [get_pblocks pb_bpuf] -add {SLICE_X22Y240:SLICE_X51Y271}
set_property CONTAIN_ROUTING TRUE [get_pblocks pb_bpuf]

# bind the whole PUF array hierarchy to the region
add_cells_to_pblock [get_pblocks pb_bpuf] [get_cells {up_proj_i/puf_bd_0/inst/u_array}]
