package main

import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:os"
import "core:strings"
import "core:time"

import SDL "vendor:sdl2"
import IMG "vendor:sdl2/image"

WINDOW_WIDTH :: 1200
WINDOW_HEIGHT :: 800

FRAME_TIME_MS :: 1000.0 / 60.0 * f64(time.Millisecond)

ASSET_SIZE :: 64

Error :: enum {
	Color,
	Clear,
	Texture,
	Copy,
}

set_render_clr :: proc(renderer: ^SDL.Renderer, clr: SDL.Color) -> (err: Error, ok: bool) {
	if ok = SDL.SetRenderDrawColor(renderer, expand_values(clr)) == 0; !ok {
		err = .Color
	}
	return
}

render_copy :: proc(
	renderer: ^SDL.Renderer,
	texture: ^SDL.Texture,
	src_rect, dst_rect: ^SDL.Rect,
) -> (
	err: Error,
	ok: bool,
) {
	if ok = SDL.RenderCopy(renderer, texture, src_rect, dst_rect) == 0; !ok {
		err = .Copy
	}
	return
}

level: string = `
xxxxx#xxxx
xxxxx#####
xxxxxxxxx#
xxx###xxx#
xxx#x#xxx#
xxx#######
xxxxx#xxxx
x#####xxxx
x#xxxxxxxx
x#xxxxxxxx
`


TileType :: enum {
	Grass1, // 024
	Grass2, // 162
	Tree1, // 131
	Tree2, // 130

	// Left right - bottom
	RoadLRB, // 001
	// Left down - bottom
	RoadLDB, // 002
	// Right down - top
	RoadRDT, // 003
	// Down right - bottom
	RoadDRB, // 299
	// Left down - top
	RoadLDT, // 004
	// down up - right
	RoadDUR, // 023
	// down up - left
	RoadDUL, // 025
	// up right - bottom
	RoadURB, // 026
	// up left - bottom
	RoadULB, // 027
	// up right - top
	RoadURT, // 046
	// right left - top
	RoadRLT, // 047
	// left up - top
	RoadLUT, // 048

	//
	Base, // 180
	Tower, // 250
}

main :: proc() {
	level = strings.trim_space(level)

	window_width: i32 = WINDOW_WIDTH
	window_height: i32 = WINDOW_HEIGHT

	window := SDL.CreateWindow(
		"Tower defense",
		SDL.WINDOWPOS_CENTERED,
		SDL.WINDOWPOS_CENTERED,
		window_width,
		window_height,
		{.RESIZABLE},
	)
	if window == nil {
		fmt.eprintln("failed to create window: ", SDL.GetErrorString())
		return
	}
	renderer := SDL.CreateRenderer(window, -1, {.ACCELERATED})
	if renderer == nil {
		fmt.eprintln("failed to create renderer: ", SDL.GetErrorString())
		return
	}

	textures := make(map[TileType]^SDL.Texture)

	{
		ASSETS_PATH :: "assets"
		fh, err := os.open(ASSETS_PATH)
		if err != nil {
			fmt.eprintln("failed to open assets dir: ", err)
			return
		}
		entries: []os.File_Info
		entries, err = os.read_dir(fh, 100)
		if err != nil {
			fmt.eprintln("failed to read dir: ", err)
			return
		}
		for entry in entries {
			tile_type: TileType
			switch entry.name {
			case "towerDefense_tile024.png":
				tile_type = .Grass1
			case "towerDefense_tile162.png":
				tile_type = .Grass2
			case "towerDefense_tile131.png":
				tile_type = .Tree1
			case "towerDefense_tile130.png":
				tile_type = .Tree2
			// roads
			case "towerDefense_tile001.png":
				tile_type = .RoadLRB
			case "towerDefense_tile002.png":
				tile_type = .RoadLDB
			case "towerDefense_tile003.png":
				tile_type = .RoadRDT
			case "towerDefense_tile004.png":
				tile_type = .RoadLDT
			case "towerDefense_tile023.png":
				tile_type = .RoadDUR
			case "towerDefense_tile025.png":
				tile_type = .RoadDUL
			case "towerDefense_tile026.png":
				tile_type = .RoadURB
			case "towerDefense_tile027.png":
				tile_type = .RoadULB
			case "towerDefense_tile046.png":
				tile_type = .RoadURT
			case "towerDefense_tile047.png":
				tile_type = .RoadRLT
			case "towerDefense_tile048.png":
				tile_type = .RoadLUT
			case "towerDefense_tile299.png":
				tile_type = .RoadDRB
			// towers
			case "towerDefense_tile180.png":
				tile_type = .Base
			case "towerDefense_tile250.png":
				tile_type = .Tower
			case:
				continue
			}

			p := strings.clone_to_cstring(entry.fullpath, allocator = context.temp_allocator)
			surface := IMG.Load(p)
			if surface == nil {
				fmt.eprintfln("failed to load asset %s: %s", entry.fullpath, SDL.GetErrorString())
				return
			}
			defer SDL.FreeSurface(surface)

			texture := SDL.CreateTextureFromSurface(renderer, surface)
			if texture == nil {
				fmt.eprintln(
					"failed to create texture for asset %s: %s",
					entry.fullpath,
					SDL.GetErrorString(),
				)
				return
			}

			assert(surface.w == ASSET_SIZE)
			assert(surface.h == ASSET_SIZE)

			textures[tile_type] = texture
		}
	}

	textures_ground := [?]^SDL.Texture {
		textures[.Grass1],
		textures[.Grass1],
		textures[.Grass2],
		textures[.Grass2],
		textures[.Tree1],
		textures[.Tree2],
	}

	MAP_TILE_COUNT :: 10
	TILE_ASSET_SIZE :: ASSET_SIZE / 2
	MAP_SIZE :: MAP_TILE_COUNT * 2 * TILE_ASSET_SIZE
	TILE_SIZE :: TILE_ASSET_SIZE * 2

	x_start := window_width / 2 - MAP_SIZE / 2
	y_start := window_height / 2 - MAP_SIZE / 2

	bg_clr := SDL.Color{43, 217, 251, 255}

	higlight: bool
	click_asset_x, click_asset_y: i32

	mouse_x, mouse_y: i32

	// angle: f64 = 0

	err: Error


	loop: for {
		// input
		start := time.tick_now()

		event: SDL.Event
		for SDL.PollEvent(&event) {
			#partial switch event.type {
			case .MOUSEBUTTONDOWN:
				if event.button.button == 1 {
					mouse_x, mouse_y := event.button.x, event.button.y

					map_x := mouse_x - x_start
					map_y := mouse_y - y_start

					if map_x >= 0 && map_y >= 0 && map_x <= MAP_SIZE && map_y <= MAP_SIZE {
						click_asset_x = map_x / TILE_ASSET_SIZE
						click_asset_y = map_y / TILE_ASSET_SIZE
						higlight = true
					}
				}
			case .MOUSEMOTION:
				mouse_x, mouse_y = event.motion.x, event.motion.y
			case .QUIT:
				return
			}
		}

		// render
		r := rand.create(1111)
		context.random_generator = rand.default_random_generator(&r)


		render_start := time.tick_now()

		err = set_render_clr(renderer, bg_clr) or_break
		if SDL.RenderClear(renderer) != 0 {
			err = .Clear
			break
		}

		x_left, y_top := x_start, y_start
		row, col := 0, 0

		render_tile :: proc(
			renderer: ^SDL.Renderer,
			x_left, y_top: i32,
			tile_asset_size: i32,
			texture_lt, texture_rt, texture_rb, texture_lb: ^SDL.Texture,
		) -> (
			err: Error,
			ok: bool,
		) {
			x_right := x_left + tile_asset_size
			y_bottom := y_top + tile_asset_size
			lt := SDL.Rect{x_left, y_top, tile_asset_size, tile_asset_size}
			rt := SDL.Rect{x_right, y_top, tile_asset_size, tile_asset_size}
			lb := SDL.Rect{x_left, y_bottom, tile_asset_size, tile_asset_size}
			rb := SDL.Rect{x_right, y_bottom, tile_asset_size, tile_asset_size}

			src_rect := SDL.Rect{0, 0, ASSET_SIZE, ASSET_SIZE}

			if texture_lt != nil {
				err = render_copy(renderer, texture_lt, &src_rect, &lt) or_return
			}
			if texture_rt != nil {
				err = render_copy(renderer, texture_rt, &src_rect, &rt) or_return
			}
			if texture_rb != nil {
				err = render_copy(renderer, texture_rb, &src_rect, &rb) or_return
			}
			if texture_lb != nil {
				err = render_copy(renderer, texture_lb, &src_rect, &lb) or_return
			}

			ok = true
			return
		}


		tiles: for tile in level {
			switch tile {
			case '\n':
				col = 0
				row += 1

				// new line
				x_left = x_start
				y_top += 2 * TILE_ASSET_SIZE
			case 'x':
				ground := textures[.Grass1]

				err = render_tile(
					renderer,
					x_left,
					y_top,
					TILE_ASSET_SIZE,
					ground,
					ground,
					ground,
					ground,
				) or_break loop

				texture1 := rand.choice(textures_ground[:])
				texture2 := rand.choice(textures_ground[:])
				texture3 := rand.choice(textures_ground[:])
				texture4 := rand.choice(textures_ground[:])

				err = render_tile(
					renderer,
					x_left,
					y_top,
					TILE_ASSET_SIZE,
					texture1,
					texture2,
					texture3,
					texture4,
				) or_break loop

				x_left += TILE_ASSET_SIZE * 2
				col += 1
			case '#':
				ln, rn, un, bn: rune

				if col > 0 {
					idx := (row * MAP_TILE_COUNT + row) + col - 1
					ln = rune(level[idx])
				}
				if col < MAP_TILE_COUNT - 1 {
					idx := (row * MAP_TILE_COUNT + row) + col + 1
					rn = rune(level[idx])
				}
				if row > 0 {
					idx := (row - 1) * MAP_TILE_COUNT + (row - 1) + col
					un = rune(level[idx])
				}
				if row < MAP_TILE_COUNT - 1 {
					idx := (row + 1) * MAP_TILE_COUNT + (row + 1) + col
					bn = rune(level[idx])
				}

				left := ln == '#'
				right := rn == '#'
				up := un == '#'
				down := bn == '#'

				texture_lt, texture_rt, texture_rb, texture_lb: ^SDL.Texture

				switch {
				case up && down && left && right:
					texture_lt = textures[.RoadLUT]
					texture_rt = textures[.RoadURT]
					texture_lb = textures[.RoadLDB]
					texture_rb = textures[.RoadDRB]
				case up && left:
					texture_lt = textures[.RoadLUT]
					texture_rt = textures[.RoadDUR]
					texture_lb = textures[.RoadLRB]
					texture_rb = textures[.RoadULB]
				case up && right:
					texture_lt = textures[.RoadDUL]
					texture_rt = textures[.RoadURT]
					texture_lb = textures[.RoadURB]
					texture_rb = textures[.RoadLRB]
				case down && left:
					texture_lt = textures[.RoadRLT]
					texture_rt = textures[.RoadLDT]
					texture_lb = textures[.RoadLDB]
					texture_rb = textures[.RoadDUR]
				case down && right:
					texture_lt = textures[.RoadRDT]
					texture_rt = textures[.RoadRLT]
					texture_lb = textures[.RoadDUL]
					texture_rb = textures[.RoadDRB]
				case up, down:
					road_left := textures[.RoadDUL]
					road_right := textures[.RoadDUR]
					texture_lt, texture_lb = road_left, road_left
					texture_rt, texture_rb = road_right, road_right
				case left, right:
					road_top := textures[.RoadRLT]
					road_bottom := textures[.RoadLRB]
					texture_lt, texture_rt = road_top, road_top
					texture_lb, texture_rb = road_bottom, road_bottom
				}

				render_tile(
					renderer,
					x_left,
					y_top,
					TILE_ASSET_SIZE,
					texture_lt,
					texture_rt,
					texture_rb,
					texture_lb,
				) or_break loop

				x_left += TILE_ASSET_SIZE * 2
				col += 1
			}
		}

		// click

		if higlight {
			texture_base := textures[.Base]
			texture_tower := textures[.Tower]

			base_dst_rect := SDL.Rect {
				x_start + click_asset_x * TILE_ASSET_SIZE,
				y_start + click_asset_y * TILE_ASSET_SIZE,
				TILE_ASSET_SIZE,
				TILE_ASSET_SIZE,
			}
			err = render_copy(renderer, texture_base, nil, &base_dst_rect) or_break loop

			tower_dst_rect := base_dst_rect
			tower_dst_rect.y -= 5

			p := SDL.Point {
				x = TILE_ASSET_SIZE / 2,
				y = TILE_ASSET_SIZE / 2 + 5,
			}

			x_diff := f64(mouse_x - (tower_dst_rect.x + p.x))
			y_diff := f64(mouse_y - (tower_dst_rect.y + p.y))
			angle := 90 + math.to_degrees(math.atan2(y_diff, x_diff))

			if SDL.RenderCopyEx(renderer, texture_tower, nil, &tower_dst_rect, angle, &p, .NONE) !=
			   0 {
				err = .Texture
				break loop
			}


			// err = render_copy(renderer, texture_tower, nil, &tower_dst_rect) or_break loop
		}

		SDL.RenderPresent(renderer)

		{
			render_duration := time.tick_since(render_start)
			title := fmt.ctprintf("Tower defense - render time: %s", render_duration)
			SDL.SetWindowTitle(window, title)
		}

		duration := time.tick_since(start)
		remaining := time.Duration(FRAME_TIME_MS - time.duration_milliseconds(duration))
		if remaining < 0 {
			continue loop
		}
		time.sleep(remaining)

		free_all(context.temp_allocator)
	}

	err_str: string
	switch err {
	case .Color:
		err_str = "failed to set draw clr: "
	case .Clear:
		err_str = "failed to clear screen: "
	case .Texture:
		err_str = "failed to copy texture: "
	case .Copy:
		err_str = "failed to copy: "
	}

	fmt.eprintln(err_str, SDL.GetErrorString())
}
