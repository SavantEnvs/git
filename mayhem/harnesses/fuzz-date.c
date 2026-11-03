#include "git-compat-util.h"
#include "date.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);

/*
 * Mayhem copy of oss-fuzz/fuzz-date.c. show_date() deliberately die()s on a timestamp that is
 * out of range for this system (local_tzoffset(), gm_time_t() in date.c): a real `git log
 * --date=...` exits the same way on such input. Upstream's harness feeds approxidate_careful()'s
 * unbounded timestamp plus a fuzzed tz straight into it, so every such input would end the
 * process and be recorded as a crash that is not a bug. Skip show_date() for exactly the
 * (mode, ts, tz) combinations that reach one of those die() checks.
 */
static int show_date_would_die(timestamp_t ts, int tz, const struct date_mode *dm)
{
	int minutes;

	if (dm->type == DATE_UNIX)
		return 0;
	if (dm->local)
		return date_overflows(ts);
	if (dm->type == DATE_RAW || dm->type == DATE_RELATIVE)
		return 0;

	minutes = tz_to_minutes(tz);
	if (minutes > 0) {
		if (unsigned_add_overflows(ts, minutes * 60))
			return 1;
	} else if (ts < -minutes * 60) {
		return 1;
	}
	return date_overflows(ts + minutes * 60);
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	int local;
	int num;
	char *str;
	int16_t tz;
	timestamp_t ts;
	enum date_mode_type dmtype;
	struct date_mode dm;

	if (size <= 4)
		/*
		 * we use the first byte to fuzz dmtype and the
		 * second byte to fuzz local, then the next two
		 * bytes to fuzz tz offset. The remainder
		 * (at least one byte) is fed as input to
		 * approxidate_careful().
		 */
		return 0;

	local = !!(*data++ & 0x10);
	num = *data++ % DATE_UNIX;
	if (num >= DATE_STRFTIME)
		num++;
	dmtype = (enum date_mode_type)num;
	size -= 2;

	tz = *data++;
	tz = (tz << 8) | *data++;
	size -= 2;

	str = xmemdupz(data, size);

	ts = approxidate_careful(str, &num);
	free(str);

	dm = date_mode_from_type(dmtype);
	dm.local = local;
	if (!show_date_would_die(ts, (int)tz, &dm))
		show_date(ts, (int)tz, dm);

	date_mode_release(&dm);

	return 0;
}
