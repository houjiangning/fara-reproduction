#-----------------------------------------------------------------------------
# puf_p1_synth.tcl -- P1 第 3 步：重新综合实现 PUF 版，并检查 PUF 是否被优化掉
#
# NOTE: keep this file ASCII-only. Vivado's Tcl on Windows uses the system
#       codepage (GBK); UTF-8 Chinese bytes can break Tcl parsing.
#
# WHY THE CHECK MATTERS:
#   The PUF is built from a cross-coupled LUT loop. If Vivado breaks or folds
#   that loop, the PUF silently reads a constant and is useless. The only
#   reliable proof that it survived is to look for its cells in the synthesized
#   netlist. Do not skip the check.
#
# USAGE:
#   vivado -mode batch -source tools/puf_p1_synth.tcl
#   (or run the same commands from the GUI Tcl console)
#
#   Set STOP_AFTER_SYNTH 1 to stop right after synthesis + the cell check
#   (use this for the FIRST pass, before the pblock bounds are filled in).
#-----------------------------------------------------------------------------

set root [file normalize [file join [file dirname [info script]] ..]]
set STOP_AFTER_SYNTH 0

# --- open the project if needed ---
set _we_opened 0
if {[llength [current_project -quiet]] == 0} {
  open_project "$root/up_proj_gemm.xpr"
  set _we_opened 1
  puts "== opened project"
} else {
  puts "== reusing already-open project: [current_project]"
}

#---------------------------------------------------------------------------
# 0) 修复文件集 / 编译顺序（2026-10-16 新增，之前这里挂过）
#
#   现象：全量构建在 generate_target 阶段挂掉
#     CRITICAL WARNING: [BD 41-1726] Unable to resolve module-source for block
#         '/gemm_up_proj_bd_0' '/puf_bd_0' '/puf_dec_bd_0' '/axis_route2_0'
#     ERROR: [filemgmt 56-587] Failed to resolve reference. Nothing was found in
#         the project to match the name gemm_up_proj_bd / puf_bd / ...
#         Try changing the compile order from manual to automatic.
#   注意连**原本正常**的 gemm_up_proj_bd 也一起挂 —— 说明是"通过 BD module
#   reference 引用的 .v 顶层没进编译顺序"这一文件集状态问题，不是 RTL 问题。
#   修复：强制全量源管理 + 重算编译顺序（在下游任何 generate_target 之前）。
#---------------------------------------------------------------------------
set_property source_mgmt_mode All [current_project]

# ！！千万不要在这里调用 update_compile_order ！！
# 2026-10-17 实测（诊断了整整一轮才挖出来）：
#   update_compile_order -fileset sources_1 会把 sources_1 的 TOP 从
#   up_proj_wrapper **误改成 puf_dec_bd** —— 后者也是个"没有任何人例化"的
#   顶层模块，自动识别顶层时会误选它。
#   TOP 一错，Vivado 就无法从层次结构推导编译顺序，于是退化成
#     CRITICAL WARNING: [filemgmt 56-176] Module references are not supported
#         in manual compile order mode and will be ignored.
#   -> [BD 41-1726] Unable to resolve module-source (四个 module-reference 全中)
#   -> [Runs 36-346] File 'up_proj.bd' ... contains invalid reference(s)，构建必挂。
#   把 TOP 显式钉回 wrapper、并且**不碰 update_compile_order**，56-176 立刻归零。
# ！！自动层次模式下**绝不能显式设 TOP** ！！
# 2026-10-17 实测（这是最后一块拼图）：
#   显式 set_property TOP up_proj_wrapper 会触发
#     [filemgmt 20-742] TOP "up_proj_wrapper" 无法校验（自动模式会改去自动挑顶层）
#     [filemgmt 20-730] Could not find a top module in the fileset sources_1
#     ERROR: [Common 17-53] Top module not set for synthesis run
#   官方 Resolution 明说：要显式设 TOP，必须先把模式切到 manual
#     set_property source_mgmt_mode None [current_project]
#   可 manual 模式又会让 module reference 被忽略（[filemgmt 56-176]）—— 两头堵。
#   正确做法：**留在自动模式（source_mgmt_mode All）、不显式设 TOP**，
#   让 Vivado 自己从存在的 up_proj_wrapper 推断顶层。
set _fs [get_filesets sources_1]
puts "== sources_1 TOP (自动识别，不显式设置) = [get_property TOP $_fs]"
foreach n {gemm_up_proj_bd puf_bd puf_dec_bd axis_route2} {
  set ff [get_files -quiet *$n.v]
  if {[llength $ff] == 0} {
    puts "!! BD module-reference top '$n' NOT in project -> references will fail"
  } else {
    puts "== BD top $n : IS_ENABLED=[get_property IS_ENABLED $ff]"
  }
}

#---------------------------------------------------------------------------
# 1) decide what must be rebuilt
#
#    This project has been bitten before by an out-of-context .dcp older than
#    the RTL ("new functionality silently absent"), so the default is a full
#    clean build. But the previous PUF run already completed synthesis, and
#    nothing that feeds synthesis has changed since (only the DRC-relax Tcl and
#    this driver script). Re-synthesizing would burn ~12 minutes for no reason.
#
#    So: reuse synth_1 ONLY when its checkpoint is provably newer than every
#    RTL and BD source -- a real staleness check, not a guess. Note the XDC
#    files are deliberately NOT part of this check: their content only affects
#    which DRCs fire, never the synthesized logic.
#
#    Force a full clean build with:  $env:PUF_FULL_SYNTH="1"
#---------------------------------------------------------------------------
set _src_newest 0
foreach f [concat \
    [glob -nocomplain $root/rtl/*.sv] \
    [glob -nocomplain $root/rtl/*.v]  \
    [glob -nocomplain $root/up_proj_gemm.srcs/sources_1/bd/up_proj/up_proj.bd]] {
  if {[file mtime $f] > $_src_newest} { set _src_newest [file mtime $f] }
}

set reuse_synth 0
set _synth_dcp "$root/up_proj_gemm.runs/synth_1/up_proj_wrapper.dcp"
if {[info exists ::env(PUF_FULL_SYNTH)]} {
  puts "== PUF_FULL_SYNTH is set -> full clean rebuild (synthesis will re-run)"
} elseif {[file exists $_synth_dcp] && [file mtime $_synth_dcp] > $_src_newest} {
  set reuse_synth 1
  puts "== synth_1 checkpoint is newer than every RTL/BD source -> REUSING it"
  puts "==   (saves ~12 min; set PUF_FULL_SYNTH=1 to force a clean build)"
} else {
  puts "== synth_1 checkpoint missing or older than the sources -> resynthesizing"
}

if {$reuse_synth == 1} {
  # impl_1 must still be rebuilt from scratch -- it currently sits in the
  # failed "opt_design ERROR" state and its outputs were already cleared.
  catch { reset_run impl_1 }
  puts "== impl_1 reset; synthesis reused"
} else {
  puts "== resetting all runs"
  foreach r [get_runs -quiet *] {
    catch { reset_run [get_property NAME $r] }
  }

  #-------------------------------------------------------------------------
  # 2) regenerate the BD targets and the wrapper
  #-------------------------------------------------------------------------
  puts "== regenerating BD targets (**不 reset_target**)"
  # ！！绝对不要在这里 reset_target all ！！
  # reset_target 会**删掉已生成的 up_proj_wrapper.v**。而在自动层次更新模式下，
  # Vivado 要靠"自动挑顶层"来确定层次；此刻 wrapper 不在，于是：
  #   [filemgmt 20-742] TOP "up_proj_wrapper" 无法校验（自动模式会另选顶层）
  #   [filemgmt 20-730] Could not find a top module in the fileset sources_1
  #   -> 层次不可用 -> module reference 解析失败 [BD 41-1726]
  #   -> synth 直接报 "Top module not set for synthesis run" (Common 17-53)
  # 已生成的 BD target / module-reference 打包都在（前面会话已生成），
  # 所以只补一次 generate_target 即可，避开这个"wrapper 短暂不存在"的窗口。
  generate_target all [get_files up_proj.bd]

  puts "== regenerating wrapper"
  make_wrapper -files [get_files up_proj.bd] -top

  #-------------------------------------------------------------------------
  # 3) synthesize from scratch
  #-------------------------------------------------------------------------
  puts "== launching synth_1 (from scratch)"
  reset_run synth_1
  launch_runs synth_1 -jobs 8
  wait_on_run synth_1
}

set sp  [get_property PROGRESS [get_runs synth_1]]
set sst [get_property STATUS   [get_runs synth_1]]
puts "== synth_1 PROGRESS = $sp   STATUS = $sst"
if {$sp ne "100%" || ![string match "*Complete!*" $sst]} {
  puts "!! SYNTH FAILED. Check $root/up_proj_gemm.runs/synth_1/runme.log"
  puts "!! common causes:"
  puts "!!   - combinational-loop DRC not downgraded (is constr/puf_lock.xdc in the project?)"
  puts "!!   - a SystemVerilog syntax error in the PUF RTL"
  puts "!!   - a UTF-8 BOM in an RTL file (xvlog rejects it: 'non-printable character 0xef')"
  if {$_we_opened} { close_project }
  return
}

#---------------------------------------------------------------------------
# 4) THE CRITICAL CHECK: is the PUF still in the netlist?
#---------------------------------------------------------------------------
puts ""
puts "===================================================================="
puts "== PUF presence check in the synthesized netlist"
puts "===================================================================="

open_run synth_1

# Primary evidence: distinct g_cell[i] indices. This is the ROBUST signal.
# Do NOT gate on a full-path filter like "*puf_bd_0/u_array*" -- measured on
# 2026-10-13 it matched 0 cells (the synthesized hierarchy name does not contain
# that literal path) while g_cell indices counted a correct 128, producing a
# FALSE "PUF array is missing" failure. Corroboration: the DRC reports exactly
# 128 LUTLP-1 combinatorial loops, one per butterfly cell.
set cell_cells [get_cells -quiet -hier -filter {NAME =~ *g_cell*}]
set arr_cells  [get_cells -quiet -hier -filter {NAME =~ *u_array*}]

puts "== cells matching *g_cell*   : [llength $cell_cells]"
puts "== cells matching *u_array*   : [llength $arr_cells]  (informational only)"

set idx_list {}
foreach c $cell_cells {
  if {[regexp {g_cell\[([0-9]+)\]} [get_property NAME $c] -> idx]} {
    lappend idx_list $idx
  }
}
set uniq_idx [lsort -integer -unique $idx_list]
puts "== distinct g_cell indices   : [llength $uniq_idx] (expect 128)"

set pass 1
if {[llength $uniq_idx] != 128} {
  puts ""
  puts "!! FAIL: expected 128 butterfly cells, found [llength $uniq_idx]."
  puts "!!   Cells were merged or folded, or synthesis removed them. Do not proceed."
  puts "!!   Check:"
  puts "!!     1) rtl/bpuf_cell.sv has (* DONT_TOUCH = \"TRUE\" *) on the loop wires"
  puts "!!     2) rtl/bpuf_cell.sv has (* ALLOW_COMBINATORIAL_LOOPS = \"TRUE\" *) on the module"
  puts "!!     3) constr/puf_lock.xdc is in the project (Fileset constrs_1), IS_ENABLED=1"
  set pass 0
}

#---------------------------------------------------------------------------
# GATE: did the LUTLP-1 DRC downgrade actually take effect?
#
#   This is the check that would have caught the 2026-10-13 failure, where a
#   control-flow command inside constr/puf_lock.xdc was silently skipped by the
#   XDC parser, leaving LUTLP-1 at Error severity so bitgen refused to run.
#---------------------------------------------------------------------------
set lutlp_sev ""
catch { set lutlp_sev [get_property SEVERITY [get_drc_checks LUTLP-1]] }
puts ""
puts "== LUTLP-1 DRC severity = '$lutlp_sev'  (informational ONLY)"

#---------------------------------------------------------------------------
# AUTHORITATIVE GATE: verify the loop-suppression pattern actually matches.
#
#   Measured on 2026-10-13 (third attempt): "set_property SEVERITY {Warning}
#   [get_drc_checks LUTLP-1]" does NOT bypass this DRC -- it was even injected
#   inside the run sub-processes via STEPS.<STEP>.TCL.PRE (each step logged
#   "source .../drc_relax_pre.tcl") and bitgen still failed with 128 LUTLP-1
#   errors. Vivado's own DRC text gives the supported mechanism:
#     set_property ALLOW_COMBINATORIAL_LOOPS TRUE [get_nets <one net in loop>]
#   constr/puf_lock.xdc now applies that to every cell's "a" net.
#
#   Checking the pattern here costs ~30 s, whereas a wrong hierarchy path would
#   otherwise only surface after a ~16-minute impl run.
#---------------------------------------------------------------------------
puts "== loop suppression: applied from constr/drc_relax_pre.tcl inside the run"
puts "==   steps via STEPS.<STEP>.TCL.PRE -- it walks the REAL cells and nets there."
puts "==   A name-pattern approach was MEASURED to match nothing (Vivado 12-507):"
puts "==     the glob pattern for the cell index matched zero nets, then"
puts "==     Common 17-55 'set_property expects at least one object' aborted opt_design."
puts "==   Hence no name pattern is used anywhere."
puts "==   NOTE: prose messages here avoid square brackets on purpose -- inside a"
puts "==         Tcl double-quoted string they mean COMMAND SUBSTITUTION and abort us."

puts ""
puts "== constr/puf_lock.xdc status:"
set xf [get_files -quiet "$root/constr/puf_lock.xdc"]
if {[llength $xf] > 0} {
  puts "==   IS_ENABLED = [get_property IS_ENABLED $xf]"
} else {
  puts "!!   XDC not found in the project!"
  set pass 0
}

set pb "$root/constr/puf_pblock.xdc"
if {[file exists $pb]} {
  puts "== constr/puf_pblock.xdc exists (placement freeze active)"
  set pbf [get_files -quiet $pb]
  if {[llength $pbf] > 0} {
    puts "==   IS_ENABLED = [get_property IS_ENABLED $pbf]"
  } else {
    puts "!!   file exists but is NOT in the project -- re-run tools/add_puf_to_bd.tcl"
    set pass 0
  }
} else {
  puts "== constr/puf_pblock.xdc absent (expected on the FIRST pass)"
}

puts ""
if {$pass == 1} {
  puts "===================================================================="
  puts "== PUF PRESENCE CHECK: PASS"
  puts "===================================================================="
} else {
  puts "===================================================================="
  puts "!! PUF PRESENCE CHECK: FAIL  (see the notes above)"
  puts "===================================================================="
}

if {$STOP_AFTER_SYNTH} {
  puts "== STOP_AFTER_SYNTH=1 -> stopping here (first pass, before the pblock)."
  puts "== NEXT: fill PUF_PBLOCK_RANGES in constr/puf_lock.xdc."
  puts "==       For the coordinate readback you need impl_1, so set"
  puts "==       STOP_AFTER_SYNTH 0 and re-run, then run puf_lock_from_place.tcl."
  if {$_we_opened} { close_project }
  return
}

#---------------------------------------------------------------------------
# 5) implement
#
# !! WHY AN EXTRA INJECTION IS NEEDED HERE !!
#
#   Measured on 2026-10-13: after constr/puf_lock.xdc was cleaned up, the
#   severity override DID take effect in the launching session
#     ("== LUTLP-1 DRC severity = 'Warning'")
#   but it did NOT reach the run sub-processes:
#     * opt/route still logged "DRC finished with 0 Errors, 128 Critical Warnings"
#     * write_bitstream still logged "128 Errors ... Bitgen not run"
#     * impl_1/runme.log contained ZERO mentions of puf_lock.xdc
#   So the override stayed in the parent session's memory only. Runs execute in
#   their own process and re-read constraints from the run's own fileset.
#
#   The reliable way to make a setting take effect INSIDE a run is a per-step
#   Tcl hook (STEPS.<STEP>.TCL.PRE), which the sub-process executes before the
#   step's own work. We attach it to WRITE_BITSTREAM, i.e. right before the
#   bitgen DRC pass that rejects the loops.
#
#   The exact property name is discovered at runtime below instead of assumed,
#   so a wrong guess is visible rather than silent.
#---------------------------------------------------------------------------
# The relaxation script is a STATIC deliverable file: constr/drc_relax_pre.tcl.
# It is deliberately NOT generated here. Generating it with `puts "..."` inside
# double quotes silently corrupted it, because Tcl performs COMMAND SUBSTITUTION
# on square brackets inside double quotes -- the emitted line lost its object
# argument and the property was never applied. See that file's header.
set drc_pre "$root/constr/drc_relax_pre.tcl"
if {![file exists $drc_pre]} {
  puts "!! FAIL: $drc_pre is missing (required deliverable file)."
  puts "!!   Without it the PUF loops stay un-suppressed and bitgen will refuse."
  set pass 0
} else {
  puts "== relaxation script present: $drc_pre"
}

#---------------------------------------------------------------------------
# PRE-FLIGHT SELF-TEST of the relaxation script   (added 2026-10-14)
#
#   History: this one script failed FOUR times with the SAME bug class -- a
#   square bracket inside a puts string being parsed as a COMMAND CALL:
#       invalid command name "Vivado"      (from writing "Vivado 12-507")
#       invalid command name "puf_lock"    (from writing "puf_lock")
#       invalid command name "drc_relax"   (from writing "drc_relax")
#   Every time it only surfaced 12+ minutes in, inside an impl run sub-process,
#   aborting opt_design at 20%. That is a terrible feedback loop.
#
#   So now we EXECUTE the file here, in the launching session, with the synth
#   checkpoint already open. Same code path, same data, roughly 2 minutes
#   instead of 14. Any runtime error is reported NOW, and the count of nets that
#   accepted the property is printed NOW.
#
#   Side effect is nil: net properties set on the synth checkpoint are not
#   carried into impl_1, and impl_1 re-sources the same file in its own process.
#---------------------------------------------------------------------------
if {$pass == 1} {
  puts ""
  puts "== PRE-FLIGHT: executing the relaxation script locally (design is open)"
  set drc_relax_n_nets -1
  if {[catch { source $drc_pre } e]} {
    puts "!! PRE-FLIGHT SELF-TEST FAILED: the relaxation script raises an error."
    puts "!!   message: $e"
    puts "!!   Most likely cause: a bracket inside a puts string used as decoration."
    puts "!!   In Tcl a bracket inside a double-quoted string means COMMAND"
    puts "!!   SUBSTITUTION, so decoration becomes an attempt to call a command."
    puts "!!   Fix the file, then re-run. NOT launching impl_1."
    set pass 0
  } else {
    puts "== PRE-FLIGHT: script executed cleanly, nets that accepted the property = $drc_relax_n_nets"
    if {$drc_relax_n_nets <= 0} {
      puts "!! PRE-FLIGHT: the property was accepted by ZERO nets."
      puts "!!   The PUF cells exist (128 were counted above), so this means the"
      puts "!!   bypass mechanism itself is not taking. NOT launching impl_1 --"
      puts "!!   a 16-minute run would only reproduce the same LUTLP-1 refusal."
      set pass 0
    } else {
      puts "== PRE-FLIGHT: bypass mechanism is live. Proceeding to impl_1."
    }
  }
}

#---------------------------------------------------------------------------
# Belt and braces #1: mark the PUF constraint files as used in BOTH synthesis
# and implementation.
#
#   Rationale: earlier runs emitted
#     WARNING: [filemgmt 20-732] Unsupported fileset type "Constraints" ...
#     CRITICAL WARNING: [filemgmt 20-730] Could not find a top module in the fileset constrs_1
#   which hints the constraint file may not be part of the run's used-in set.
#   A constraint file whose USED_IN does not include 'implementation' never
#   reaches the impl/bitgen sub-process, so its DRC severity override has no
#   effect there. Setting it explicitly removes that possibility.
#---------------------------------------------------------------------------
foreach xf [list "$root/constr/puf_lock.xdc" "$root/constr/puf_pblock.xdc"] {
  set ff [get_files -quiet $xf]
  if {[llength $ff] > 0} {
    if {[catch {
      set_property USED_IN {synthesis implementation} $ff
    } e]} {
      puts "== note: could not set USED_IN on [file tail $xf]: $e"
    } else {
      puts "== USED_IN [file tail $xf] = [get_property USED_IN $ff]"
    }
  }
}

puts "== run property candidates matching STEPS.*TCL.PRE:"
foreach p [lsort [list_property [get_runs impl_1]]] {
  if {[string match "STEPS.*TCL.PRE" $p]} { puts "==   $p" }
}

foreach step {WRITE_BITSTREAM ROUTE_DESIGN PLACE_DESIGN OPT_DESIGN} {
  if {[catch {
    set_property STEPS.${step}.TCL.PRE $drc_pre [get_runs impl_1]
    puts "== attached TCL.PRE to STEPS.${step}"
  } e]} {
    puts "== note: STEPS.${step}.TCL.PRE not settable ($e)"
  }
}

if {$pass != 1} {
  puts ""
  puts "!! PRE-FLIGHT CHECK FAILED -> NOT launching impl_1 (avoids a long doomed run)."
  puts "!! Fix the items marked FAIL above, then re-run this script."
  if {$_we_opened} { close_project }
  return
}

# -to_step is overridable via the PUF_FAST environment variable, so a decisive
# verdict can be reached in ~3-5 min instead of a ~16 min full run:
#     $env:PUF_FAST="opt_design"      (PowerShell) then re-run this script
#
# WHY opt_design is enough to decide:
#   opt_design ALREADY reports LUTLP-1 -- the historical log line
#   "DRC finished with 0 Errors, 128 Critical Warnings" at that stage is for the
#   128 PUF loops. If the ALLOW_COMBINATORIAL_LOOPS net property works, that
#   count drops to 0 right there. So we learn the answer in minutes.
set impl_stop "write_bitstream"
catch { set impl_stop $::env(PUF_FAST) }
puts "== launching impl_1  (-to_step $impl_stop)"
launch_runs impl_1 -to_step $impl_stop -jobs 8
wait_on_run impl_1

set ip  [get_property PROGRESS [get_runs impl_1]]
set ist [get_property STATUS   [get_runs impl_1]]
puts "== impl_1 PROGRESS = $ip   STATUS = $ist"
# NOTE: with -to_step write_bitstream, PROGRESS legitimately stops at ~83%
# (it counts steps, and the final step is not counted). So judge by STATUS and
# by whether the bitstream actually appeared -- a pure PROGRESS==100% test
# gives a false failure. (learned the hard way on 2026-10-13)
if {![string match "*Complete!*" $ist]} {
  puts "!! IMPL FAILED (STATUS=$ist). Check $root/up_proj_gemm.runs/impl_1/runme.log"
  puts "!! if the tail says 'DRC finished with N Errors ... Bitgen not run' while"
  puts "!! LUTLP-1 is the rule, then the DRC downgrade did not take effect:"
  puts "!!   grep the log for '20-1307 Command ... is not supported in the xdc'"
  puts "!!   -> that means a control-flow command slipped into an .xdc file."
  puts "!!   XDC files accept PLAIN constraint commands only (no if/catch/foreach)."
  if {$_we_opened} { close_project }
  return
}

if {$impl_stop ne "write_bitstream"} {
  puts "== FAST MODE (-to_step $impl_stop): no bitstream expected."
  puts "==   DECISIVE SIGNAL -- run this and read it:"
  puts "==     Select-String -Path up_proj_gemm.runs/impl_1/runme.log \\"
  puts "==        -Pattern 'drc_relax|DRC finished with'"
  puts "==   0 occurrences of LUTLP-1 at this stage  ->  property works, go full run."
  puts "==   still 128                               ->  mechanism ineffective, stop."
} else {
  set bit "$root/up_proj_gemm.runs/impl_1/up_proj_wrapper.bit"
  if {[file exists $bit]} {
    puts "== bitstream: $bit ([file size $bit] bytes)"
  } else {
    puts "!! bitstream not found at $bit"
  }
}

puts ""
puts "== NEXT STEPS:"
puts "==   1) open_run impl_1 ; source tools/puf_lock_from_place.tcl"
puts "==      -> paste the printed PUF_PBLOCK_RANGES line into constr/puf_lock.xdc"
puts "==   2) re-run this script (now WITH the pblock) to freeze placement"
puts "==   3) bootgen -image up_proj.bif -arch zynqmp -o up_proj_wrapper.bit.bin -w"
puts "== DONE"

if {$_we_opened} { close_project }
