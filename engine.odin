package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:time"

import ma "vendor:miniaudio"

SAMPLE_RATE :: 44100
CHANNELS :: 2

MAX_FRAMES :: 128 * 1024 * CHANNELS

WAVE_SIZE :: 88200

MAX_VALUE :: 32767
MIN_VALUE :: -32767

Wave :: struct {
  data: []i64,
  size: u64,
  hz: f64,
}

WAVEFORMS :: 99

wave: [WAVEFORMS]Wave

Voice :: struct {
  waveform: i16,
  hz: f64,
  dds_inc: i64,
  dds_acc: u64,
  dds_mod: i16,
  dds_modscale: i64,
  gain: f64,
  gain_val: i64,
  sample: i64,
  audible: bool,
  ismod: bool,
}

VOICES :: 16

synth: [VOICES]Voice

mksine :: proc(size: int) -> []i64 {
  sine_table := make([]i64, size)
  fsize := f64(len(sine_table))
  for i in 0..<len(sine_table) {
    phase := f64(i)
    x := MAX_VALUE * math.sin(math.TAU * f64(phase) / fsize)
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
    x := 0
    if i < half {
      x = MAX_VALUE
    } else {
      x = -MAX_VALUE
    }
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
GAIN_FRAC :: 8
GAIN_SCALE :: 1 << GAIN_FRAC
GAIN_MASK :: GAIN_SCALE-1

dds_inc := i32(0)
dds_acc := u64(0)

wave_freq :: proc(voice: int, f: f64) {
  synth[voice].hz = f
  synth[voice].dds_inc = i64( f * f64(WAVE_SIZE) / SAMPLE_RATE * DDS_SCALE  )
}

gain_val := i64(0)

AMY_FACTOR :: 0.025

wave_gain :: proc(voice: int, g: f64) {
  synth[voice].gain = g
  ag := g * AMY_FACTOR
  synth[voice].gain_val = i64( ag * f64(GAIN_SCALE) )
}

wave_next :: proc(voice: int) -> i64 {
  index := synth[voice].dds_acc >> DDS_FRAC
  /*
  // only is this wave is one-shot
  if index > WAVE_SIZE {
    index = 0
  }
  */
  fmod := i64(0)
  vmod := synth[voice].dds_mod
  if vmod >= 0 {
    fmod = synth[vmod].sample
  }
  mod := i64(fmod)
  if mod != 0 {
    scale := synth[voice].dds_modscale
    mod *= scale
  }
  thewave := wave[synth[voice].waveform]
  sample := thewave.data[index % thewave.size]
  synth[voice].sample = sample
  synth[voice].dds_acc += ( u64(synth[voice].dds_inc + mod ) )
  return sample
}

DDS_MOD_SCALE :: 4

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
  for i in 0..<frame_count {
    left := i16(0)
    right := i16(0)
    for v in 0..<VOICES {
      sample := wave_next(v) * synth[v].gain_val / GAIN_SCALE
      synth[v].sample = sample
      samplei16 := i16( sample )
      if !synth[v].ismod {
        left += samplei16
        right += samplei16
      }
    }
    out_s16[fi+0] = left
    out_s16[fi+1] = right
    fi += CHANNELS
  }

}

show_voice :: proc(voice: int, flag: bool) {
  s := " "
  if flag {
    s = "*"
  }
  m := "0"
  if synth[voice].ismod {
    m = "1"
  }
  fmt.printf("%s v%d w%d f%g a%g F%d FS%d M%s # %d (%d,%d)\n",
        s,
        voice,
        synth[voice].waveform,
        synth[voice].hz,
        synth[voice].gain,
        synth[voice].dds_mod,
        synth[voice].dds_modscale,
        m,
        //
        synth[voice].dds_inc,
        synth[voice].dds_inc >> DDS_FRAC,
        0
      )
}

engine: ma.engine

context_type: ma.context_type

pPlaybackInfos: ^ma.device_info
playbackCount: u32

pCaptureInfos: ^ma.device_info
captureCount: u32

config: ma.device_config
device: ma.device

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
    wave[w].hz = 0
  }

  wave[0].data = mksine(WAVE_SIZE)
  wave[0].size = WAVE_SIZE
  
  wave[1].data = mksqr(WAVE_SIZE)
  wave[1].size = WAVE_SIZE

  wave[2].data = mksawup(WAVE_SIZE)
  wave[2].size = WAVE_SIZE

  wave[3].data = mksawdn(WAVE_SIZE)
  wave[3].size = WAVE_SIZE

  wave[4].data = mktri(WAVE_SIZE)
  wave[4].size = WAVE_SIZE
  
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
    synth[v].dds_acc = 0
    synth[v].dds_inc = 0
    synth[v].gain_val = 0
    synth[v].audible = true
    synth[v].dds_mod = -1
    synth[v].dds_modscale = DDS_SCALE
  }

  current_voice := 0
  for {
    buf: [256]byte
    n, err := os.read(os.stdin, buf[:])
    if err != nil || n <= 1 {
      break
    }
    if buf[0] == 'f' {
      str := string(buf[1:n])
      f := strconv.atof(str)
      wave_freq(current_voice, f)
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
    } else if buf[0] == 'M' {
      str := string(buf[1:n])
      if str[0] == '1' {
        synth[current_voice].ismod = true
      } else {
        synth[current_voice].ismod = false
      }
    } else if buf[0] == 'F' {
      if buf[1] == 'S' {
        str := string(buf[2:n])
        s := strconv.atoi(str)
        synth[current_voice].dds_modscale = i64(s)
      } else {
        str := string(buf[1:n])
        v := strconv.atoi(str)
        if v >= 0 && v < VOICES {
          synth[v].ismod = true
          synth[current_voice].dds_mod = i16(v)
        } else {
          synth[current_voice].dds_mod = -1
        }
      }
  } else if buf[0] == 'w' {
      str := string(buf[1:n])
      w := strconv.atoi(str)
      if w >= 0 && w < WAVEFORMS {
        synth[current_voice].waveform = i16(w)
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
  }
}
