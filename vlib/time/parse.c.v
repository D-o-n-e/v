// Copyright (c) 2019-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module time

// parse returns time from a date string in "YYYY-MM-DD HH:MM:SS" format.
pub fn parse(s string) ?Time {
	pos := s.index(' ') or { return error('Invalid time format: $s') }
	symd := s[..pos]
	ymd := symd.split('-')
	if ymd.len != 3 {
		return error('Invalid time format: $s')
	}
	shms := s[pos..]
	hms := shms.split(':')
	hour_ := hms[0][1..]
	minute_ := hms[1]
	second_ := hms[2]
	res := new_time(Time{
		year: ymd[0].int()
		month: ymd[1].int()
		day: ymd[2].int()
		hour: hour_.int()
		minute: minute_.int()
		second: second_.int()
	})
	return res
}

// parse_rfc2822 returns time from a date string in RFC 2822 datetime format.
pub fn parse_rfc2822(s string) ?Time {
	fields := s.split(' ')
	if fields.len < 5 {
		return error('Invalid time format: $s')
	}
	pos := months_string.index(fields[2]) or { return error('Invalid time format: $s') }
	mm := pos / 3 + 1
	unsafe {
		tmstr := malloc_noscan(s.len * 2)
		count := C.snprintf(&char(tmstr), (s.len * 2), c'%s-%02d-%s %s', fields[3].str,
			mm, fields[1].str, fields[4].str)
		return parse(tos(tmstr, count))
	}
}

// ----- rfc3339 -----
const (
	err_invalid_3339 = 'Invalid 3339 format'
)

// parse_rfc3339 returns time from a date string in RFC 3339 datetime format.
pub fn parse_rfc3339(s string) ?Time {
	if s == '' {
		return error(time.err_invalid_3339 + ' cannot parse empty string')
	}
	mut t := parse_iso8601(s) or { Time{} }
	// If parse_iso8601 DID NOT result in default values (i.e. date was parsed correctly)
	if t != Time{} {
		return t
	}

	t_i := s.index('T') or { -1 }
	parts := if t_i != -1 { [s[..t_i], s[t_i + 1..]] } else { s.split(' ') }

	// Check if s is date only
	if !parts[0].contains_any(' Z') && parts[0].contains('-') {
		year, month, day := parse_iso8601_date(s) ?
		t = new_time(Time{
			year: year
			month: month
			day: day
		})
		return t
	}
	// Check if s is time only
	if !parts[0].contains('-') && parts[0].contains(':') {
		mut hour_, mut minute_, mut second_, mut microsecond_, mut unix_offset, mut is_local_time := 0, 0, 0, 0, i64(0), true
		hour_, minute_, second_, microsecond_, unix_offset, is_local_time = parse_iso8601_time(parts[0]) ?
		t = new_time(Time{
			hour: hour_
			minute: minute_
			second: second_
			microsecond: microsecond_
		})
		if is_local_time {
			return t // Time is already local time
		}
		mut unix_time := t.unix
		if unix_offset < 0 {
			unix_time -= (-unix_offset)
		} else if unix_offset > 0 {
			unix_time += unix_offset
		}
		t = unix2(i64(unix_time), t.microsecond)
		return t
	}

	return error(time.err_invalid_3339 + '. Could not parse "$s"')
}

// ----- iso8601 -----
const (
	err_invalid_8601 = 'Invalid 8601 Format'
)

fn parse_iso8601_date(s string) ?(int, int, int) {
	year, month, day, dummy := 0, 0, 0, byte(0)
	count := unsafe { C.sscanf(&char(s.str), c'%4d-%2d-%2d%c', &year, &month, &day, &dummy) }
	if count != 3 {
		return error(time.err_invalid_8601)
	}
	return year, month, day
}

fn parse_iso8601_time(s string) ?(int, int, int, int, i64, bool) {
	hour_ := 0
	minute_ := 0
	second_ := 0
	microsecond_ := 0
	plus_min_z := `a`
	offset_hour := 0
	offset_minute := 0
	mut count := unsafe {
		C.sscanf(&char(s.str), c'%2d:%2d:%2d.%6d%c%2d:%2d', &hour_, &minute_, &second_,
			&microsecond_, &char(&plus_min_z), &offset_hour, &offset_minute)
	}
	// Missread microsecond ([Sec Hour Minute].len == 3 < 4)
	if count < 4 {
		count = unsafe {
			C.sscanf(&char(s.str), c'%2d:%2d:%2d%c%2d:%2d', &hour_, &minute_, &second_,
				&char(&plus_min_z), &offset_hour, &offset_minute)
		}
		count++ // Increment count because skipped microsecond
	}
	if count < 4 {
		return error(time.err_invalid_8601)
	}
	is_local_time := plus_min_z == `a` && count == 4
	is_utc := plus_min_z == `Z` && count == 5
	if !(count == 7 || is_local_time || is_utc) {
		return error(time.err_invalid_8601)
	}
	if plus_min_z != `+` && plus_min_z != `-` && !is_utc && !is_local_time {
		return error('Invalid 8601 format, expected `Z` or `+` or `-` as time separator')
	}
	mut unix_offset := 0
	if offset_hour > 0 {
		unix_offset += 3600 * offset_hour
	}
	if offset_minute > 0 {
		unix_offset += 60 * offset_minute
	}
	if plus_min_z == `+` {
		unix_offset *= -1
	}
	return hour_, minute_, second_, microsecond_, unix_offset, is_local_time
}

// parse_iso8601 parses rfc8601 time format yyyy-MM-ddTHH:mm:ss.dddddd+dd:dd as local time
// the fraction part is difference in milli seconds and the last part is offset
// from UTC time and can be both +/- HH:mm
// remarks: not all iso8601 is supported
// also checks and support for leapseconds should be added in future PR
pub fn parse_iso8601(s string) ?Time {
	t_i := s.index('T') or { -1 }
	parts := if t_i != -1 { [s[..t_i], s[t_i + 1..]] } else { s.split(' ') }
	if !(parts.len == 1 || parts.len == 2) {
		return error(time.err_invalid_8601)
	}
	year, month, day := parse_iso8601_date(parts[0]) ?
	mut hour_, mut minute_, mut second_, mut microsecond_, mut unix_offset, mut is_local_time := 0, 0, 0, 0, i64(0), true
	if parts.len == 2 {
		hour_, minute_, second_, microsecond_, unix_offset, is_local_time = parse_iso8601_time(parts[1]) ?
	}
	mut t := new_time(Time{
		year: year
		month: month
		day: day
		hour: hour_
		minute: minute_
		second: second_
		microsecond: microsecond_
	})
	if is_local_time {
		return t // Time already local time
	}
	mut unix_time := t.unix
	if unix_offset < 0 {
		unix_time -= (-unix_offset)
	} else if unix_offset > 0 {
		unix_time += unix_offset
	}
	t = unix2(i64(unix_time), t.microsecond)
	return t
}
