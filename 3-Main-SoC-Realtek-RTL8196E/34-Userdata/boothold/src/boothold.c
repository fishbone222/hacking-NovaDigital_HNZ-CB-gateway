/*
 * boothold — Write HOLD magic to DRAM for bootloader entry
 *
 * Writes 0x484F4C44 ("HOLD") to physical address 0x01FFEFFC via /dev/mem.
 * The bootloader (V2.6+) reads this address via KSEG1 (uncached) on next
 * reset and enters download mode if it finds the magic word.  The flag
 * is one-shot: the bootloader clears it before entering download mode.
 *
 * Does NOT reboot — the caller handles that (e.g. `boothold && reboot`).
 *
 * Why 0x01FFEFFC (high DRAM, just below btcode stack)?
 *
 *   v2.x firmware (Linux 5.10) used 0x003FFFFC at the bottom of DRAM.
 *   On Linux 6.18 (v3.0.0+) that became unreliable: ~13-27% of boots
 *   the bootloader read 0 (or kernel-code-like values) instead of HOLD.
 *   The 6.18 kernel scribbles low DRAM during early init / shutdown
 *   before the reserved-memory `no-map` declaration is honored.
 *
 *   The fix is to put HOLD high in DRAM, just below the btcode stack
 *   (which lives at the very top, 0x01FFFFFC and growing down).  The
 *   page 0x01FFE000-0x01FFEFFF is reserved-memory no-map in the device
 *   tree and is far above any address the kernel touches in early boot
 *   (kernel image is loaded at phys 0x00500000).  100% reliable.
 *
 * Build: mips-lexra-linux-musl-gcc -Os -static -o boothold boothold.c
 */

#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdint.h>
#include <arpa/inet.h>

#define HOLD_PHYS   0x01FFEFFC
#define HOLD_MAGIC  0x484F4C44  /* "HOLD" */

int main(void)
{
	int fd;
	uint32_t val, readback;

	fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (fd < 0) {
		perror("open /dev/mem");
		return 1;
	}

	val = htonl(HOLD_MAGIC);
	if (pwrite(fd, &val, sizeof(val), HOLD_PHYS) != sizeof(val)) {
		perror("pwrite");
		close(fd);
		return 1;
	}

	if (pread(fd, &readback, sizeof(readback), HOLD_PHYS) != sizeof(readback)) {
		perror("pread");
		close(fd);
		return 1;
	}

	close(fd);

	if (readback != val) {
		fprintf(stderr, "boothold: verify failed (wrote 0x%08X, read 0x%08X)\n",
			ntohl(val), ntohl(readback));
		return 1;
	}

	printf("Boot hold set.\n");
	return 0;
}
