# AMD Hackintosh: the "Fix PAT" kernel patch makes every write-combined mapping uncached

**One byte.** The AMD_Vanilla OpenCore patch `Algrey / Zormeister | _mtrr_update_action | Fix PAT` programs the CPU's
Page Attribute Table with Linux's layout. macOS uses a different PAT slot for write-combining, so on every AMD
Hackintosh using this patch, **all write-combined (WC) memory mappings are silently uncached**. GPU drivers map VRAM
(BAR) for the CPU as write-combined, so CPU→VRAM writes run at a fraction of their speed.

Changing one byte of the patch's `Replace` data puts write-combining back where macOS expects it.

> **NVIDIA GPUs only.** On AMD Radeon GPUs this change causes GPU hangs. See [Who is affected](#who-is-affected).

Measured on a Ryzen 7 9800X3D + RTX 5080 (macOS 26, NullMoth NVIDIA driver), same machine, before / after:

| | before | after |
|---|---|---|
| CPU → VRAM, 8-byte stores | 1.40 GB/s | **27.4 GB/s** |
| Kernel clear of new VRAM (`rep stosq`) | 1.09 GB/s | **15 GB/s** |
| Wrap a new 4K IOSurface as a Metal texture | 32.3 ms | **2.9 ms** |
| 160 Hz animation while windows are resized (40 new window buffers/s) | 100 fps, 38% late frames | **166 fps, 0–0.3% late** |
| WindowServer GPU time on a saturated GPU timeline | 20.3% | **8.8%** |

Window resizing went from visibly stuttering to smooth.

## Who is affected

Anyone booting macOS on an AMD CPU with the AMD_Vanilla `_mtrr_update_action | Fix PAT` kernel patch enabled
(MinKernel 24.0.0 / macOS 15+ in current AMD_Vanilla), whose GPU driver uses write-combined CPU mappings.
- Verified: NVIDIA RTX 5080 with the NullMoth driver.
- **Not for AMD Radeon.** DrogaBox tested it on an RX 6800 XT (Navi 21), Ryzen 9 5900XT, macOS 26.7.1: constant GPU
  hangs (20 GPU resets in 9 minutes), gone again on Shaneee's patch. On Radeon it also gives no speedup: the macOS Radeon
  driver has no write-combined VRAM path. Details and analysis:
  [AMD-OSX/AMD_Vanilla#216](https://github.com/AMD-OSX/AMD_Vanilla/pull/216).

### Why it hangs Radeon GPUs (DrogaBox's analysis)

The CPU's hardware prefetcher crosses 4 KB page boundaries. After a cached access to one page, the first few dozen lines
of the next physical page can sit in the CPU cache. If that next page is RAM mapped write-combined, WC stores do not
update or drop the cached copy, and a GPU that snoops the CPU cache reads the stale line. On Navi 21 this leaves the GFX
ring stuck in the middle of an indirect buffer. His workaround is an extra kernel patch that keeps RAM pages write-back,
so that only device memory is write-combined. See the PR thread.

On NVIDIA (Zen 5, RTX 5080) the fix has run for days without a GPU reset. The same mechanism could still affect any
write-combined RAM that the GPU reads with snooping, so treat it as experimental.

## The bug

The x86 PAT has 8 entries (PA0–PA7). A page's PAT/PCD/PWT bits pick one of them, so the OS decides which entry
means "write-combining".

- **XNU (macOS)** keeps the power-on layout and sets **PA6 = WC**. See `pat_init()` in `osfmk/i386/mtrr.c`: "Change PA6
  attribute field to WC". Its pmap maps `VM_WIMG_WCOMB` pages through PAT index 6. The kernel bytes this patch
  replaces are exactly that read-modify-write: `and edx,0xff00ffff ; or edx,0x00010000 ; wrmsr`.
- **Linux** puts WC at **PA1** and leaves PA6 = UC-.
- **The AMD_Vanilla patch** replaces XNU's read-modify-write with the fixed value `PAT = 0x0007010600070106`, which is
  Linux's layout:

```
            PA7  PA6  PA5  PA4  PA3  PA2  PA1  PA0
AMD_Vanilla  UC   UC-  WC   WB   UC   UC-  WC   WB     edx = 0x00070106, eax = 0x00070106
this fix     UC   WC   WC   WB   UC   UC-  WC   WB     edx = 0x00010106, eax = 0x00070106
```

With PA6 = UC-, everything macOS maps as write-combined becomes uncached: every 8-byte store is its own bus
transaction. That is why CPU→VRAM bandwidth collapses to ~1.4 GB/s, while 64-byte stores, which need no combining,
still reach ~11 GB/s.

## The fix

In the patch entry, change `Replace` from

```
89c0 b806010700 ba06010700 0f30 9090    base64 icC4BgEHALoGAQcADzCQkA==
```
to
```
89c0 b806010700 ba06010100 0f30 9090    base64 icC4BgEHALoGAQEADzCQkA==
```

Only PA6 changes, from UC- to WC; the other seven entries stay byte-for-byte the same. `Find`, `Mask`, `MinKernel`
and `MaxKernel` stay as they are. The full corrected entry is in [`patch-entry.plist`](patch-entry.plist).

### With the script

```bash
sudo bash apply_pat_wc.sh /Volumes/EFI/EFI/OC/config.plist on     # apply (backs up config.plist first)
sudo bash apply_pat_wc.sh /Volumes/EFI/EFI/OC/config.plist off    # revert to the original AMD_Vanilla bytes
```

The script finds the entry by its `Find`/`Mask` bytes, not by index, and only touches it when the current `Replace`
is one of the two known values. Reboot to apply.

If something goes wrong, boot Recovery, mount the EFI partition (`diskutil mount disk0sX`) and copy the
`config.plist.backup-*` file back.

## Compared with the other AMD_Vanilla PAT patch

AMD_Vanilla also ships Shaneee's PAT patch. Its README says it "will increase GPU performance on AMD GPUs but can stop
NVIDIA GPUs from booting" and may cause HDMI/DisplayPort audio issues. The PAT values explain why:

```
             PA7  PA6  PA5  PA4  PA3  PA2  PA1  PA0
Algrey        UC   UC-  WC   WB   UC   UC-  WC   WB     write-combining lost (this bug)
Shaneee       WB   WB   WB   WB   WB   WB   WB   WB     everything cacheable, including MMIO
this fix      UC   WC   WC   WB   UC   UC-  WC   WB     what XNU intends: PA6 = WC, UC stays UC
```

## Older macOS (10.13 – 14)

AMD_Vanilla's `algrey | _mtrr_update_action | fix PAT | 10.13+` entry has the same problem and the same one-byte fix:
`Replace` `b977020000 b806010700 ba06010700 0f1f4000` (`uXcCAAC4BgEHALoGAQcADx9AAA==`) becomes
`b977020000 b806010700 ba06010100 0f1f4000` (`uXcCAAC4BgEHALoGAQEADx9AAA==`). The script only handles the 15.0+ entry;
edit the older one by hand. Untested, because no 10.13–14 system was available.

## Upstream

Proposed to AMD_Vanilla as opt-in entries in [AMD-OSX/AMD_Vanilla#216](https://github.com/AMD-OSX/AMD_Vanilla/pull/216).

## Checking it

macOS gives user space no way to read the PAT MSR, so check the effect:
- **NVIDIA + NullMoth:** build `tools/barwc.m`:
  ```bash
  xcrun clang -O2 -fobjc-arc tools/barwc.m -framework Metal -o barwc
  ```
  Then run it with Shared buffers placed in VRAM (`NVMTL_PROCESS_ENV=1 NVMTL_SHARED_VRAM=1 ./barwc`). 8-byte stores
  should run close to 64-byte stores: tens of GB/s instead of ~1.4 GB/s.
- **Any GPU:** anything that streams CPU data into VRAM (texture uploads, window buffers) gets dramatically faster.

## Credits

The original patch is by **algrey** and **Zormeister**, from [AMD_Vanilla](https://github.com/AMD-OSX/AMD_Vanilla).
This repository only corrects which PAT entry holds write-combining.

---

# 中文说明

AMD 黑苹果常用的 OpenCore 内核补丁 `Algrey / Zormeister | _mtrr_update_action | Fix PAT`，把 CPU 的页属性表（PAT）写成了 Linux 的布局。

- macOS 自己把"写合并"（WC）放在第 6 项（PA6）。
- 这个补丁把第 6 项写成了"不缓存"（UC-）。

结果是 macOS 里所有"写合并"的内存映射都悄悄变成了不缓存。显卡驱动给 CPU 映射显存用的正是写合并，所以 CPU 往显存写数据会慢一个数量级。

**修法：只改补丁 `Replace` 里的一个字节，把 `ba06010700` 改成 `ba06010100`，让第 6 项回到写合并，其余 7 项完全不变。**

实测（9800X3D + RTX 5080，macOS 26，NullMoth 驱动，同一台机器修复前后对比）：

| 项目 | 修复前 | 修复后 |
|---|---|---|
| CPU 写显存（8 字节写） | 1.40 GB/s | 27.4 GB/s |
| 内核清零新显存 | 1.09 GB/s | 15 GB/s |
| 新建一个 4K 窗口缓冲 | 32 ms | 2.9 ms |
| 拖窗口改大小时的 160Hz 动画 | 100 帧，38% 掉帧 | 166 帧，掉帧 0–0.3% |
| WindowServer 合成占 GPU | 20% | 9% |

拖窗口从明显卡顿变成流畅。用法见上面的英文部分：脚本 `apply_pat_wc.sh` 会先备份配置，`on` 是应用修复，`off` 是改回原值，重启生效。

**注意：只适用于 NVIDIA 显卡，Radeon 不能用。** DrogaBox 在 RX 6800 XT（Navi 21）上实测：只改这一项会让显卡反复卡死（9 分钟重置 20 次）。

原因是 CPU 预取器会把下一页内存的开头几十行提前读进缓存；那一页如果是被设成写合并的普通内存，写合并的写入不会更新缓存里的旧副本，会探查 CPU 缓存的显卡就读到了旧数据。Radeon 上这个改动也没有提速。

NVIDIA 上已经稳定运行多天，但这一机制理论上同样可能影响，请把它当作实验性修改。

原项目里的另一个 PAT 补丁（Shaneee 的）把 8 项全部设成"可缓存"，硬件寄存器也被缓存了，所以原项目说明里写着它可能让 N 卡开不了机、HDMI/DP 音频出问题。本修复只把第 6 项改回写合并，其余不动。macOS 10.13–14 用的旧版补丁有同样的问题，同样改一个字节（见上面英文部分），脚本只处理 15.0+ 那一条。已向原项目提交 PR：[AMD-OSX/AMD_Vanilla#216](https://github.com/AMD-OSX/AMD_Vanilla/pull/216)。

原补丁作者是 AMD_Vanilla 的 algrey 和 Zormeister，本仓库只修正了写合并所在的那一项。
