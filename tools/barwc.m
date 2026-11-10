// barwc: is the CPU's view of VRAM write-combined? Write-combined memory merges narrow stores, so 8-byte and 64-byte
// stores reach similar bandwidth; uncached memory sends every store on its own, so 8-byte stores are far slower.
#import <Metal/Metal.h>
#include <immintrin.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <string.h>
static double us(void){ static mach_timebase_info_data_t t; if(!t.denom) mach_timebase_info(&t); return mach_absolute_time()*(double)t.numer/t.denom/1e3; }
__attribute__((target("avx512f"))) static void st64(char *p, size_t n){ __m512i z=_mm512_set1_epi32(7); for(size_t i=0;i<n;i+=64) _mm512_store_si512((void*)(p+i), z); }
__attribute__((target("avx512f"))) static void nt64(char *p, size_t n){ __m512i z=_mm512_set1_epi32(7); for(size_t i=0;i<n;i+=64) _mm512_stream_si512((void*)(p+i), z); _mm_sfence(); }
static void st8(char *p, size_t n){ volatile uint64_t *q=(volatile uint64_t*)p; for(size_t i=0;i<n/8;i++) q[i]=7; }
int main(){ @autoreleasepool {
  id<MTLDevice> d = MTLCreateSystemDefaultDevice(); const size_t n = 64u<<20;
  id<MTLBuffer> b = [d newBufferWithLength:n options:MTLResourceStorageModeShared]; char *p = (char*)b.contents;
  char *h = aligned_alloc(64, n);
  struct { const char *nm; void (*f)(char*,size_t); } t[] = {{"8B stores",st8},{"64B AVX-512 stores",st64},{"64B non-temporal",nt64}};
  for (int i=0;i<3;i++){ double best=1e30; for(int r=0;r<3;r++){ double a=us(); t[i].f(p,n); double e=us()-a; if(e<best)best=e; }
    double bh=1e30; for(int r=0;r<3;r++){ double a=us(); t[i].f(h,n); double e=us()-a; if(e<bh)bh=e; }
    printf("%-20s Shared buffer %6.2f GB/s   | host RAM %6.1f GB/s\n", t[i].nm, n/best/1e3, n/bh/1e3); }
}}
