package t1

import "core:fmt"
import "core:thread"
import "core:time"
import rl "vendor:raylib"

t1run := true

t1 :: proc(t: ^thread.Thread) {
  fmt.println("begin t1")
  for t1run {
    fmt.println("loop t1")
    time.sleep(1 * time.Second)
  }
  fmt.println("end t1")
}

t2 :: proc(t: ^thread.Thread) {
}

main :: proc() {
  fmt.println("main start")
  t := thread.create(t1)
  thread.start(t)
  for i in 0..<5 {
    fmt.printf("%d...\n", i)
    time.sleep(100 * time.Millisecond)
  }
  rl.SetConfigFlags({.VSYNC_HINT})
  rl.InitWindow(640,480, "scope")
  for !rl.WindowShouldClose() {
    rl.BeginDrawing()
    rl.ClearBackground(rl.DARKBLUE)
    rl.EndDrawing()
  }
  run = false
  thread.join(t)
  thread.destroy(t)
  fmt.println("main done")
}
