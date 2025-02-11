package main

import "core:fmt"
import "core:io"
import "core:math"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:time"

import ma "vendor:miniaudio"

import "core:thread"
import rl "vendor:raylib"

t1len :: 5000
t1h :: 256
t1w :: 512
t1buf: [t1len]i16
t1ptr := 0
t1run := true
t1th: ^thread.Thread
t1 :: proc(t: ^thread.Thread) {
  rl.SetConfigFlags({.VSYNC_HINT})
  rl.InitWindow(t1w,t1h, "scope")
  for !rl.WindowShouldClose() {
    rl.BeginDrawing()
    rl.ClearBackground(rl.BLACK)
    for i in 0..<t1len {
      cx := mapper(i, 0, t1len, 0, t1w-1)
      cy := mapper(int(t1buf[i]), MIN_VALUE, MAX_VALUE, 0, t1h-1)
      rl.DrawRectangle(i32(cx), i32(cy), 1, 1, rl.GREEN)
    }
    rl.EndDrawing()
  }
}

SAMPLE_RATE :: 44100
CHANNELS :: 2

MAX_FRAMES :: 128 * 1024 * CHANNELS

WAVE_SIZE :: 44100

MAX_VALUE :: 32767
MIN_VALUE :: -32767

Wave :: struct {
  data: []i64,
  size: u64,
  usehz: bool,
  loop: bool,
  hz: f64,
}

WAVEFORMS :: 99

wave: [WAVEFORMS]Wave


/*

time-ms,level
o


attack time -- starts when parameter of 'l' is > 0 ... that number is the sustain level, sets gate true
decay time -- starts when parameter of 'l' is == 0 ... sets gate false


gate = off -> to-sustain -> sustained -> to-release -> off



*/

GATE_OFF :: 0
GATE_TO_SUSTAIN :: 1
GATE_SUSTAINED :: 2
GATE_TO_RELEASE :: 3

Voice :: struct {
  waveform: int,
  alt_waveform: int, // future wave morph?
  hz: f64,
  gate: int, // state used by 'l'? and ADSR see notes above
  wave_inc: i64,
  wave_acc: u64,
  wave_mod: i16,
  wave_modexp: int,
  wave_modscale: i64,
  gain: f64,
  attack_ms: int, // used by 'A'
  decay_ms: int, // used by 'A'
  gain_val: i64, // used by 'a'
  gain_inc: i64, // used by 'l'?
  gain_acc: i64, // used by 'l'?
  gain_limit: i64, // used by 'l'?
  sample: i64,
  alt_sample: i64, // future wave morph?
  audible: bool,
  ismod: bool,
  running: bool,
  loop: bool,
}

VOICES :: 16

synth: [VOICES]Voice

mksine :: proc(size: int) -> []i64 {
  sine_table := make([]i64, size)
  for i in 0..<size {
    phase := f64(i)
    x := MAX_VALUE * math.sin(math.TAU * f64(phase) / f64(size))
    sine_table[i] = i64(x)
  }
  return sine_table
}

mktri :: proc(size: int) -> []i64 {
  table := make([]i64, size)
  fsize := f64(len(table))
  half := size/2
  for i in 0..<len(table) {
    phase := f64(i)
    x := 0
    
    if i < half {
      x = (2 * MAX_VALUE * i + half - 1) / half
    } else {
      x = (2 * MAX_VALUE * (size - i - 1) + half - 1) / half
    }
    table[i] = i64(x-MAX_VALUE)
  }
  return table
}

mksqr :: proc(size: int) -> []i64 {
  table := make([]i64, size)
  fsize := f64(len(table))
  half := size/2
  for i in 0..<len(table) {
    x := MAX_VALUE if i < half else MIN_VALUE
    table[i] = i64(x)
  }
  return table
}

mksawup :: proc(size: int) -> []i64 {
  table := make([]i64, size)
  fsize := f64(len(table))
  acc := f64(MIN_VALUE)
  rate := MAX_VALUE * 2 / f64(size)
  for i in 0..<len(table) {
    table[i] = i64(acc)
    acc += rate
  }
  return table
}

mksawdn :: proc(size: int) -> []i64 {
  table := make([]i64, size)
  fsize := f64(len(table))
  acc := f64(MAX_VALUE)
  rate := MAX_VALUE * 2 / f64(size)
  for i in 0..<len(table) {
    table[i] = i64(acc)
    acc -= rate
  }
  return table
}

/*

  waveform size 88200 (this is 1 second of waveform)
  sample rate   44100
  frequency       440
  inc = waveform size / sample rate * frequency = 880

*/

// for Q17.16 = max freq = 2^17 or 131072 Hz
DDS_FRAC :: 15
DDS_SCALE :: 1 << DDS_FRAC
DDS_MASK :: DDS_SCALE-1

// for Q8.24
GAIN_FRAC :: 15
// GAIN_FRAC :: 8
GAIN_SCALE :: 1 << GAIN_FRAC
GAIN_MASK :: GAIN_SCALE-1

wave_freq :: proc(voice: int, f: f64) {
  synth[voice].hz = f
  size := wave[synth[voice].waveform].size
  if wave[synth[voice].waveform].usehz {
    hz := wave[synth[voice].waveform].hz
    synth[voice].wave_inc = i64( f / hz * DDS_SCALE )
  } else {
    synth[voice].wave_inc = i64( f * f64(size) / SAMPLE_RATE * DDS_SCALE  )
  }
}

// gain_val := i64(0)

AMY_FACTOR :: 0.025

wave_gain :: proc(voice: int, g: f64) {
  synth[voice].gain = g
  ag := g * AMY_FACTOR
  synth[voice].gain_val = i64( ag * f64(GAIN_SCALE) )
}

wave_reset :: proc(voice: int) {
  synth[voice].wave_acc = 0
  synth[voice].running = true
}

wave_next :: proc(voice: int) -> i64 {
  if synth[voice].running == false {
    return 0
  }
  index := synth[voice].wave_acc >> DDS_FRAC
  fmod := i64(0)
  vmod := synth[voice].wave_mod
  if vmod >= 0 {
    fmod = synth[vmod].sample
  }
  mod := i64(fmod)
  if mod != 0 {
    scale := synth[voice].wave_modscale
    mod *= scale
  }
  thewave := wave[synth[voice].waveform]
  sample := thewave.data[index % thewave.size]
  synth[voice].sample = sample
  synth[voice].wave_acc += ( u64(synth[voice].wave_inc + mod ) )
  if index >= thewave.size {
    if synth[voice].loop == false {
      synth[voice].running = false
      synth[voice].wave_acc = 0
    }
  }
  index = index % thewave.size
  return sample
}

exsynthia :: proc(device: ^ma.device, output, input: rawptr, frame_count: u64) {
  out_s16 := cast(^[MAX_FRAMES]i16)(output)
  
  /*
  // can this happen?
  if frame_count > MAX_FRAMES {
    return
  }
  */

  fi := u64(0)

  i: u64
  saturatedmin := false
  saturatedmax := false
  for i in 0..<frame_count {
    left := i16(0)
    right := i16(0)
    for v in 0..<VOICES {
      sample := wave_next(v) * synth[v].gain_val / GAIN_SCALE
      // saturation...
      if sample > MAX_VALUE {
        sample = MAX_VALUE
        saturatedmax = true
      } else if sample < MIN_VALUE {
        sample = MIN_VALUE
        saturatedmin = true
      }
      synth[v].sample = sample
      samplei16 := i16( sample )
      if !synth[v].ismod {
        if saturatedmin {
          left = MIN_VALUE
          right = MIN_VALUE
        } else if saturatedmax {
          left = MAX_VALUE
          right = MAX_VALUE
        } else {
          left += samplei16
          right += samplei16
        }
      }
    }
    out_s16[fi+0] = left
    out_s16[fi+1] = right
    t1buf[t1ptr] = (left+right)/2
    t1ptr += 1
    if t1ptr >= t1len {
      t1ptr = 0
    }
    fi += CHANNELS
  }

}

show_voice :: proc(voice: int, flag: bool) {
  s := "*" if flag else " "
  m := 1 if synth[voice].ismod else 0
  b := 1 if synth[voice].loop else 0

  F := "x" if synth[voice].wave_mod < 0 else fmt.tprintf("%d", synth[voice].wave_mod)

  fmt.printf("%s v%d w%d b%d f%g a%g F%s FS%d M%d A%d # inc:%g\n",
        s,
        voice,
        synth[voice].waveform,
        b,
        synth[voice].hz,
        synth[voice].gain,
        F,
        synth[voice].wave_modexp,
        m,
        synth[voice].attack_ms,
        //
        f64(synth[voice].wave_inc) / f64(DDS_SCALE)
      )
}

bm :: struct {
  cols: int,
  rows: int,
  pixel: [][]int,
  color: [][]int,
  braille: [][]int,
}

makebm :: proc(cols:int, rows:int) -> bm {
  b: bm
  b.cols = cols
  b.rows = rows

  b.pixel = make([][]int, cols)
  for i in 0..<len(b.pixel) {
    b.pixel[i] = make([]int, rows)
  }
  /*
    unicode braille is
    oo
    oo
    oo
    oo
    so divide cols by 2 and rows by 4 in the render array

    static uint16_t pixel_map[4][2] = {
      {0x01, 0x08},
      {0x02, 0x10},
      {0x04, 0x20},
      {0x40, 0x80},
    };

    int getoffset(int16_t x, int16_t y) {
      return (y * _COLS + x);
    }

    void set(int16_t x, int16_t y, int16_t c) {
      int offset;
      if (x < 0) x = 0;
      if (y < 0) y = 0;
      if (x >= COLS-1) x = COLS-1;
      if (y >= ROWS-1) y = ROWS-1;
      uint16_t p = pixel_map[y % 4][x % 2];
      x /= 2;
      y /= 4;
      offset = getoffset(x, y);
      if (offset < sizeof(canvas)) {
          canvas[offset] |= p;
          if (colors[offset] == 0) {
              colors[offset] = c;
          } else {
              if (c < 0) {
                  colors[offset] = -c;
              }
          }
      }
    }
    
    #define UNICODE_BOX (0x2500)
    #define UNICODE_BRAILLE (0x2800)

    int utf8_encode(char *out, uint32_t utf) {
      if (utf <= 0x7F) {
          // Plain ASCII
          out[0] = (char) utf;
          out[1] = 0;
          return 1;
      } else if (utf <= 0x07FF) {
          // 2-byte unicode
          out[0] = (char) (((utf >> 6) & 0x1F) | 0xC0);
          out[1] = (char) (((utf >> 0) & 0x3F) | 0x80);
          out[2] = 0;
          return 2;
      } else if (utf <= 0xFFFF) {
          // 3-byte unicode
          out[0] = (char) (((utf >> 12) & 0x0F) | 0xE0);
          out[1] = (char) (((utf >>  6) & 0x3F) | 0x80);
          out[2] = (char) (((utf >>  0) & 0x3F) | 0x80);
          out[3] = 0;
          return 3;
      } else if (utf <= 0x10FFFF) {
          // 4-byte unicode
          out[0] = (char) (((utf >> 18) & 0x07) | 0xF0);
          out[1] = (char) (((utf >> 12) & 0x3F) | 0x80);
          out[2] = (char) (((utf >>  6) & 0x3F) | 0x80);
          out[3] = (char) (((utf >>  0) & 0x3F) | 0x80);
          out[4] = 0;
          return 4;
      } else {
          // error - use replacement character
          out[0] = (char) 0xEF;
          out[1] = (char) 0xBF;
          out[2] = (char) 0xBD;
          out[3] = 0;
          return 0;
      }
    }

  */
  b.braille = make([][]int, cols/2)
  for i in 0..<len(b.braille) {
    b.braille[i] = make([]int, rows/4)
  }
  return b
}

setbm :: proc(b: bm, x: int, y:int, c:int) {
  ax := 0 if x < 0 else x
  ax = b.rows-1 if ax > b.rows-1 else ax
  ay := 0 if y < 0 else y
  ay = b.cols-1 if ay > b.cols-1 else ay
  b.pixel[ay][ax] = c
}

showbm :: proc(b: bm) {
  for y in 0..<b.rows {
    for x in 0..<b.cols {
      if b.pixel[x][y] == 1 {
        fmt.printf("#")
      } else {
        fmt.printf(" ")
      }
    }
    fmt.printf("\n")
  }
}

mapper :: proc(x: int, in_min: int, in_max: int, out_min: int, out_max: int) -> int {
  return (x - in_min) * (out_max - out_min) / (in_max - in_min) + out_min
}

engine: ma.engine

context_type: ma.context_type

pPlaybackInfos: ^ma.device_info
playbackCount: u32

pCaptureInfos: ^ma.device_info
captureCount: u32

config: ma.device_config
device: ma.device

wire :: proc(voice:int, buf: []byte, n: int) -> (int, bool) {
  current_voice := voice
  running := true
  //
  if buf[0] == 'f' {
    str := string(buf[1:n])
    f := strconv.atof(str)
    wave_freq(current_voice, f)
  } else if buf[0] == ':' {
    if buf[1] == 'q' {
      running = false
      t1run = false
    }
    if buf[1] == 'g' {
      t1th = thread.create(t1)
      thread.start(t1th)
    }
  } else if buf[0] == 'b' {
    str := string(buf[1:n])
    b := strconv.atoi(str)
    synth[current_voice].loop = true if b == 1 else false
  } else if buf[0] == 'l' {
    str := string(buf[1:n])
    g := strconv.atof(str)
    synth[current_voice].gate = GATE_TO_SUSTAIN
    wave_reset(current_voice)
    wave_gain(current_voice, g)
  } else if buf[0] == 'A' {
    str := string(buf[1:n])
    a := strconv.atoi(str)
    if a >= 0 {
      synth[current_voice].attack_ms = a
      /*
        44100 / 1000 = 44.1ms per sample
        so if A10 (attack of 10ms)
        'l4' would be achieved in 10ms
        which means the increment from 0 to 4
        means a gain increase of X every 441 samples
      */
    }
  } else if buf[0] == 'a' {
    str := string(buf[1:n])
    g := strconv.atof(str)
    wave_gain(current_voice, g)
  } else if buf[0] == 'v' {
    str := string(buf[1:n])
    v := strconv.atoi(str)
    if v >= 0 && v < VOICES {
      current_voice = v
    }
  } else if buf[0] == 'n' {
    str := string(buf[1:n])
    n := strconv.atof(str)
    f := 440.0 * math.pow(2.0, (n - 69.0) / 12.0)
    wave_freq(current_voice, f)
  } else if buf[0] == 'M' {
    str := string(buf[1:n])
    synth[current_voice].ismod = true if str[0] == '1' else false
  } else if buf[0] == 'F' {
    if buf[1] == 'S' {
      str := string(buf[2:n])
      s := strconv.atoi(str)
      exp := i64(1 << u64(s))
      synth[current_voice].wave_modexp = s
      synth[current_voice].wave_modscale = exp
    } else {
      str := string(buf[1:n])
      v := strconv.atoi(str)
      if v >= 0 && v < VOICES {
        synth[v].ismod = true
        synth[current_voice].wave_mod = i16(v)
      } else {
        synth[current_voice].wave_mod = -1
      }
    }
} else if buf[0] == '<' {
  if buf[1] == 'p' {
    str := string(buf[2:n])
    p := strconv.atoi(str)
    fmt.println("load patch", p)
    config: ma.decoder_config
    result: ma.result
    frame_count: u64
    samples_ptr: rawptr
    result = ma.decode_file("024.wav", &config, &frame_count, &samples_ptr)
    if result != .SUCCESS {
      fmt.println("decode_file failed")
    } else {
      // fmt.printf("frame_count:%d\n", frame_count)
      // fmt.println(config)
      if config.format == .s16 && config.channels == 2 && config.sampleRate == SAMPLE_RATE {
        samples_ptr_i16 := cast(^i16)(samples_ptr)
        total_samples := int(frame_count * 2)
        samples := mem.slice_ptr(samples_ptr_i16, total_samples)
        // fmt.println("samples", len(samples))
        // mem.free(samples_ptr)
        wave[p].data = make([]i64, frame_count)
        j := 0
        for i:=0; i<int(total_samples); i+=2 {
          x := i64((samples[i] + samples[i+1]) / 2)
          wave[p].data[j] = x
          j+=1
        }
        wave[p].size = u64(j)
        wave[p].usehz = true
        wave[p].loop = false
        wave[p].hz = 440.0
      }
    }
  }
} else if buf[0] == 'W' {
  str := string(buf[1:n])
    w := strconv.atoi(str)
    if w >= 0 && w < WAVEFORMS {
      COLS := 80
      ROWS := 20
      b := makebm(COLS, ROWS)
      table := wave[w].data
      size := int(wave[w].size)
      info := "hz-base" if wave[w].usehz else "size-base"
      loop := "loop" if wave[w].loop else "1-shot"
      fmt.printf("size:%d %s %gHz %s\n",
        size,
        info,
        wave[w].hz,
        loop
      )
      for i in 0..<size {
        x := table[i]
        cx := mapper(int(x), MIN_VALUE, MAX_VALUE, 0, ROWS-1)
        cy := mapper(i, 0, size, 0, COLS-1)
        setbm(b, cx, cy, 1)
      }
      showbm(b)
    }
} else if buf[0] == 'w' {
    str := string(buf[1:n])
    w := strconv.atoi(str)
    if w >= 0 && w < WAVEFORMS {
      last_wave := synth[current_voice].waveform
      synth[current_voice].waveform = w
      if w != last_wave {
        synth[current_voice].loop = wave[w].loop
        wave_reset(current_voice)
        wave_freq(current_voice, synth[current_voice].hz)
      }
    }
  } else if buf[0] == '?' {
    if buf[1] == '?' { 
      for v in 0..<VOICES {
        if synth[v].hz > 0 && synth[v].gain > 0 {
          show_voice(v, v == current_voice)
        }
      }
    } else {
      show_voice(current_voice, false)
    }
  }
  //
  return current_voice, running
}

import psx "core:sys/posix"
orig_mode: psx.termios

enable_raw_mode :: proc() {
  res := psx.tcgetattr(psx.STDIN_FILENO, &orig_mode)
  //psx.atexit(disable_raw_mode)
  raw := orig_mode
  raw.c_lflag -= {.ECHO, .ICANON}
  res = psx.tcsetattr(psx.STDIN_FILENO, .TCSANOW, &raw)
}

disable_raw_mode :: proc() {
  res := psx.tcsetattr(psx.STDIN_FILENO, .TCSANOW, &orig_mode)
}

main :: proc() {
  args := os.args
  fmt.println(args)

  result: ma.result

  result = ma.context_init(nil, 0, nil, &context_type)
  if result != .SUCCESS {
    fmt.println("context_init failed")
    os.exit(1)
  }
  defer ma.context_uninit(&context_type)
  
  playback_info: [^]ma.device_info
  playbacks: u32
  capture_info: [^]ma.device_info
  captures: u32
  result = ma.context_get_devices(&context_type,
    &playback_info,
    &playbacks,
    &capture_info,
    &captures)
  if result != .SUCCESS {
    fmt.println("context_get_devices failed")
    os.exit(1)
  }

  playback_id: ma.device_id
  for p in playback_info[:playbacks] {
    if p.isDefault {
      fmt.printf("playback using %s\n", p.name)
      playback_id = p.id
      break
    }
  }

  capture_id: ma.device_id
  for c in capture_info[:captures] {
    if c.isDefault {
      fmt.printf("capture using %s\n", c.name)
      capture_id = c.id
      break
    }
  }

  config = ma.device_config_init(ma.device_type.playback)
  config.playback.pDeviceID = &playback_id
  config.playback.format = ma.format.s16
  config.playback.channels = CHANNELS
  config.sampleRate = SAMPLE_RATE
  config.dataCallback = ma.device_data_proc(exsynthia)

  config.periodSizeInFrames = 1024
  config.periods = 2

  // config.periodSizeInMilliseconds = 10
  // config.periods = 1

  empty := make([]i64, 1)
  empty[0] = 0
  for w in 0..<WAVEFORMS {
    wave[w].data = empty
    wave[w].size = 1
    wave[w].hz = 1
    wave[w].usehz = false
    wave[w].loop = true
  }

  wave[0].data = mksine(WAVE_SIZE)
  wave[0].size = u64(len(wave[0].data))
  
  wave[1].data = mksqr(WAVE_SIZE/2)
  wave[1].size = u64(len(wave[1].data))

  wave[2].data = mksawup(WAVE_SIZE)
  wave[2].size = u64(len(wave[2].data))

  wave[3].data = mksawdn(WAVE_SIZE)
  wave[3].size = u64(len(wave[3].data))

  wave[4].data = mktri(WAVE_SIZE)
  wave[4].size = u64(len(wave[4].data))
  
  result = ma.device_init(nil, &config, &device)
  if result != .SUCCESS {
    fmt.println("did not init")
    os.exit(1)
  }
  defer ma.device_uninit(&device)
  
  result = ma.device_start(&device)
  if result != .SUCCESS {
    fmt.println("did not start")
    os.exit(1)
  }
  defer ma.device_stop(&device)

  for v in 0..<VOICES {
    synth[v].waveform = 0
    synth[v].wave_acc = 0
    synth[v].wave_inc = 0
    synth[v].gain_val = 0
    synth[v].running = true
    synth[v].audible = true
    synth[v].loop = true
    synth[v].wave_mod = -1
    synth[v].wave_modscale = DDS_SCALE
    synth[v].wave_modexp = DDS_FRAC
    //
    synth[v].gate = GATE_OFF
  }

  fmt.println("# test raw mode... press ESC for wire console")
  enable_raw_mode()
  defer disable_raw_mode()
  in_stream := os.stream_from_handle(os.stdin)
  running := true
  for running {
    ch, sz, err := io.read_rune(in_stream)
    switch {
      case err != nil:
        break
      case:
        fmt.printf("%02x ", ch, flush=false)
        if ch == 27 {
          running = false
        }
    }
  }
  disable_raw_mode()

  fmt.println("# Hlokk console. ctrl-d or :q to exit")
  current_voice := 0
  running = true
  for running {
    buf: [256]byte
    fmt.printf("# ")
    n, err := os.read(os.stdin, buf[:])
    if err != nil || n == 0 {
      break
    }
    current_voice, running = wire(current_voice, buf[:], n)
  }
}
