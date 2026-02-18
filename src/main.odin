package main

import "base:runtime"
import "core:c"
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

FRAME_TIME_MS :: 1000.0 / 144.0 * f64(time.Millisecond)

ASSET_SIZE :: 64
TILE_SIZE :: 32

SDL_Error :: struct {
	loc: runtime.Source_Code_Location,
	msg: string,
}

Error :: union {
	SDL_Error,
}

error_string :: proc(error: Error, allocator := context.temp_allocator) -> (s: string) {
	switch e in error {
	case SDL_Error:
		s = fmt.aprintf(
			"%s SDL Error: %s: %s",
			e.loc,
			e.msg,
			SDL.GetErrorString(),
			allocator = allocator,
		)
	}
	return
}

sdl_exec :: proc(res: c.int, msg := "", loc := #caller_location) -> (err: Error) {
	if res != 0 {
		err = SDL_Error {
			loc = loc,
			msg = msg,
		}
	}
	return
}

// render_tower :: proc(
// 	renderer: ^SDL.Renderer,
// 	textures: map[TileType]^SDL.Texture,
// 	dst_point: SDL.Point,
// 	angle_point: ^SDL.Point,
// ) -> (
// 	err: Error,
// 	ok: bool,
// ) {
// 	base_dst_rect := SDL.Rect {
// 		x = dst_point.x,
// 		y = dst_point.y,
// 		w = TILE_ASSET_SIZE,
// 		h = TILE_ASSET_SIZE,
// 	}
// 	render_copy(renderer, textures[.Base], nil, &base_dst_rect) or_return
//
// 	tower_dst_rect := base_dst_rect
// 	tower_dst_rect.y -= 5
//
// 	if angle_point != nil {
// 		tower_center_point := SDL.Point {
// 			x = TILE_ASSET_SIZE / 2,
// 			y = TILE_ASSET_SIZE / 2 + 5,
// 		}
//
// 		x_diff := f64(angle_point.x - (tower_dst_rect.x + tower_center_point.x))
// 		y_diff := f64(angle_point.y - (tower_dst_rect.y + tower_center_point.y))
// 		angle := 90 + math.to_degrees(math.atan2(y_diff, x_diff))
//
// 		if SDL.RenderCopyEx(
// 			   renderer,
// 			   textures[.Tower],
// 			   nil,
// 			   &tower_dst_rect,
// 			   angle,
// 			   &tower_center_point,
// 			   .NONE,
// 		   ) !=
// 		   0 {
// 			err = .Texture
// 			return
// 		}
// 	} else {
// 		render_copy(renderer, textures[.Tower], nil, &tower_dst_rect) or_return
// 	}
//
// 	ok = true
// 	return
// }

Mouse :: struct {
	using _: SDL.Point,
	btn:     u32,
}

Context :: struct {
	window:        ^SDL.Window,
	renderer:      ^SDL.Renderer,
	frame_time:    time.Duration,
	textures:      map[Texture]^SDL.Texture,

	//
	window_width:  i32,
	window_height: i32,
	zoom:          f32,
	mouse:         Mouse,

	// clr
	bg_clr:        SDL.Color,
}

TextureGround :: enum {
	Grass1, // 024
	Grass2, // 162
}

TextureRoad :: enum {
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
}

TextureEntity :: enum {
	None,
	CardTower, // 038
	Base, // 180
	Tower, // 250
}

TextureDecoration :: enum {
	None,
	Tree1, // 131
	Tree2, // 130
}

Texture :: union {
	TextureGround,
	TextureRoad,
	TextureDecoration,
	TextureEntity,
}

TileGround :: struct {
	texture:    TextureGround,
	decoration: TextureDecoration,
	tower:      TextureEntity,
}

Tile :: union {
	TileGround,
	TextureRoad,
}

Level :: struct {
	using _:      SDL.Rect,
	cols, rows:   int,
	tiles:        [dynamic]Tile,
	hovered_tile: int,
}

level_init :: proc(level: ^Level, level_map: string, allocator := context.allocator) {
	level_map := strings.trim_space(level_map)
	map_rows, map_cols: int

	for tile in level_map {
		switch tile {
		case '\n':
			map_rows += 1
			level.rows += 2
		case:
			if level.rows == 0 {
				map_cols += 1
				level.cols += 2
			}
		}
	}

	map_rows += 1
	map_cols += 1 // account for '\n' at the end

	level.rows += 2
	level.w = i32(level.cols) * TILE_SIZE
	level.h = i32(level.rows) * TILE_SIZE
	level.tiles = make([dynamic]Tile, level.rows * level.cols)

	set_tiles :: proc(level: ^Level, row, col: int, lt, rt, lb, rb: Tile) {
		t_idx := row * level.cols + col
		level.tiles[t_idx] = lt // left top
		level.tiles[t_idx + 1] = rt // right top

		b_idx := (row + 1) * level.cols + col
		level.tiles[b_idx] = lb // left bottom
		level.tiles[b_idx + 1] = rb // right bottom
	}

	row, col := 0, 0

	tiles: for tile, idx in level_map {
		switch tile {
		case '\n':
			col = 0
			row += 2
		case 'x':
			new_ground :: proc() -> TileGround {
				t := TileGround {
					texture = rand.choice_enum(TextureGround),
				}
				if rand.uint64_range(0, 10) >= 7 {
					t.decoration = rand.choice_enum(TextureDecoration)
				}
				return t
			}
			set_tiles(level, row, col, new_ground(), new_ground(), new_ground(), new_ground())
			col += 2
		case '#':
			map_row := idx / map_cols
			map_col := idx - map_cols * map_row
			ln, rn, un, bn: rune
			if map_col > 0 {
				ln = rune(level_map[idx - 1])
			}
			if map_col < map_cols - 2 {
				rn = rune(level_map[idx + 1])
			}
			if map_row > 0 {
				un = rune(level_map[idx - map_cols])
			}
			if map_row < map_cols - 2 {
				bn = rune(level_map[idx + map_cols])
			}

			left := ln == '#'
			right := rn == '#'
			up := un == '#'
			down := bn == '#'

			switch {
			case up && down && left && right:
				set_tiles(level, row, col, .RoadLUT, .RoadURT, .RoadLDB, .RoadDRB)
			case up && left:
				set_tiles(level, row, col, .RoadLUT, .RoadDUR, .RoadLRB, .RoadULB)
			case up && right:
				set_tiles(level, row, col, .RoadDUL, .RoadURT, .RoadURB, .RoadLRB)
			case down && left:
				set_tiles(level, row, col, .RoadRLT, .RoadLDT, .RoadLDB, .RoadDUR)
			case down && right:
				set_tiles(level, row, col, .RoadRDT, .RoadRLT, .RoadDUL, .RoadDRB)
			case up, down:
				set_tiles(level, row, col, .RoadDUL, .RoadDUR, .RoadDUL, .RoadDUR)
			case left, right:
				set_tiles(level, row, col, .RoadRLT, .RoadRLT, .RoadLRB, .RoadLRB)
			}

			col += 2
		}
	}

	return
}

level_coords :: proc(level: ^Level, ctx: ^Context) {
	level.x = ctx.window_width / 2 - i32(level.cols) * TILE_SIZE / 2
	level.y = ctx.window_height / 2 - i32(level.cols) * TILE_SIZE / 2
}

Ui :: struct {
	using _:        SDL.Point,
	padding:        i32,
	card_w, card_h: i32,
	cards:          i32,
	card_clicked:   i32,
	card_click_pos: SDL.Point,
}

ui_coords :: proc(ui: ^Ui, ctx: ^Context) {
	ui.x = ctx.window_width - ui.card_w - ui.padding
	ui.y = ctx.window_height / 2 - (ui.cards * ui.card_h + ui.padding * (ui.cards - 2)) / 2
}

render :: proc(ctx: ^Context, level: ^Level, ui: ^Ui) -> (err: Error) {
	render_start := time.tick_now()
	defer {
		render_duration := time.tick_since(render_start)
		title := fmt.ctprintf(
			"Tower defense - frame time %s render time: %s",
			ctx.frame_time,
			render_duration,
		)
		SDL.SetWindowTitle(ctx.window, title)
	}

	sdl_exec(SDL.SetRenderDrawColor(ctx.renderer, expand_values(ctx.bg_clr))) or_return
	sdl_exec(SDL.RenderClear(ctx.renderer)) or_return

	{ 	// render level
		texture_rect := SDL.Rect {
			w = TILE_SIZE,
			h = TILE_SIZE,
		}

		for tile, idx in level.tiles {
			row := idx / level.rows
			col := idx - level.cols * row

			texture_rect.x = level.x + i32(col) * TILE_SIZE
			texture_rect.y = level.y + i32(row) * TILE_SIZE

			highlight_clr: SDL.Color

			switch t in tile {
			case TileGround:
				sdl_exec(
					SDL.RenderCopy(ctx.renderer, ctx.textures[t.texture], nil, &texture_rect),
				) or_return

				if t.decoration != nil {
					sdl_exec(
						SDL.RenderCopy(
							ctx.renderer,
							ctx.textures[t.decoration],
							nil,
							&texture_rect,
						),
					) or_return
					highlight_clr = SDL.Color{255, 100, 100, 100}
				} else {
					highlight_clr = SDL.Color{100, 255, 100, 100}
				}

				#partial switch t.tower {
				case .Tower:
					sdl_exec(
						SDL.RenderCopy(ctx.renderer, ctx.textures[.Base], nil, &texture_rect),
					) or_return

					tower_r := texture_rect
					tower_r.y -= 5
					sdl_exec(
						SDL.RenderCopy(ctx.renderer, ctx.textures[.Tower], nil, &tower_r),
					) or_return
				}
			case TextureRoad:
				sdl_exec(
					SDL.RenderCopy(ctx.renderer, ctx.textures[t], nil, &texture_rect),
				) or_return
				highlight_clr = SDL.Color{255, 100, 100, 100}
			}

			if idx == level.hovered_tile {
				sdl_exec(
					SDL.SetRenderDrawColor(ctx.renderer, expand_values(highlight_clr)),
				) or_return
				sdl_exec(SDL.RenderFillRect(ctx.renderer, &texture_rect)) or_return
			}
		}
	}

	{ 	// render ui
		mouse_x, mouse_y := ctx.mouse.x, ctx.mouse.y

		x := ui.x
		y := ui.y

		for i in 0 ..< ui.cards {
			temp_x, temp_y := x, y
			defer {
				x = temp_x
				y = temp_y
				y += ui.card_h + ui.padding
			}

			w, h := ui.card_w, ui.card_h
			tower_w, tower_h: i32 = 32, 32

			if i == ui.card_clicked {
				w = 32
				h = 32
				x = mouse_x - min(ui.card_click_pos.x, w)
				y = mouse_y - min(ui.card_click_pos.y, h)

				tower_w, tower_h = 20, 20
			} else {
				inside_x := mouse_x >= x && mouse_x <= x + ui.card_w
				inside_y := mouse_y >= y && mouse_y <= y + ui.card_h

				if inside_x && inside_y {
					y -= 5
				}
			}

			card_r := SDL.Rect{x, y, w, h}
			sdl_exec(
				SDL.RenderCopy(ctx.renderer, ctx.textures[.CardTower], nil, &card_r),
			) or_return

			base_r := SDL.Rect {
				x = card_r.x + card_r.w / 2 - tower_w / 2,
				y = card_r.y + card_r.h / 2 - tower_h / 2,
				w = tower_w,
				h = tower_h,
			}
			sdl_exec(SDL.RenderCopy(ctx.renderer, ctx.textures[.Base], nil, &base_r)) or_return

			tower_r := base_r
			tower_r.y -= 5
			sdl_exec(SDL.RenderCopy(ctx.renderer, ctx.textures[.Tower], nil, &tower_r)) or_return
		}
	}

	SDL.RenderPresent(ctx.renderer)

	return
}

main :: proc() {
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

	textures := make(map[Texture]^SDL.Texture)
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
			texture_key: Texture
			switch entry.name {
			// grounds
			case "towerDefense_tile024.png":
				texture_key = .Grass1
			case "towerDefense_tile162.png":
				texture_key = .Grass2
			// decorations
			case "towerDefense_tile131.png":
				texture_key = .Tree1
			case "towerDefense_tile130.png":
				texture_key = .Tree2
			// roads
			case "towerDefense_tile001.png":
				texture_key = .RoadLRB
			case "towerDefense_tile002.png":
				texture_key = .RoadLDB
			case "towerDefense_tile003.png":
				texture_key = .RoadRDT
			case "towerDefense_tile004.png":
				texture_key = .RoadLDT
			case "towerDefense_tile023.png":
				texture_key = .RoadDUR
			case "towerDefense_tile025.png":
				texture_key = .RoadDUL
			case "towerDefense_tile026.png":
				texture_key = .RoadURB
			case "towerDefense_tile027.png":
				texture_key = .RoadULB
			case "towerDefense_tile046.png":
				texture_key = .RoadURT
			case "towerDefense_tile047.png":
				texture_key = .RoadRLT
			case "towerDefense_tile048.png":
				texture_key = .RoadLUT
			case "towerDefense_tile299.png":
				texture_key = .RoadDRB
			// towers
			case "towerDefense_tile180.png":
				texture_key = .Base
			case "towerDefense_tile250.png":
				texture_key = .Tower
			case "towerDefense_tile038.png":
				texture_key = .CardTower
			case:
				continue
			}

			p := strings.clone_to_cstring(entry.fullpath, allocator = context.temp_allocator)
			surface := IMG.Load(p)
			if surface == nil {
				err := SDL_Error {
					loc = #location(),
					msg = fmt.aprintf(
						"failed to load \"%s\" texture: ",
						entry.fullpath,
						allocator = context.temp_allocator,
					),
				}
				fmt.eprintln(error_string(err))
				return
			}
			defer SDL.FreeSurface(surface)

			texture := SDL.CreateTextureFromSurface(renderer, surface)
			if texture == nil {
				err := SDL_Error {
					loc = #location(),
					msg = fmt.aprintf(
						"failed to create \"%s\" texture: ",
						entry.fullpath,
						allocator = context.temp_allocator,
					),
				}
				fmt.eprintln(error_string(err))
				return
			}

			assert(surface.w == ASSET_SIZE)
			assert(surface.h == ASSET_SIZE)

			textures[texture_key] = texture
		}
	}

	ctx := Context {
		window        = window,
		renderer      = renderer,
		window_width  = window_width,
		window_height = window_height,
		textures      = textures,
		bg_clr        = SDL.Color{110, 150, 200, 255},
	}

	levelTiles: string =
		"xxxxx#xxxx\n" +
		"xxxxx#####\n" +
		"xxxxxxxxx#\n" +
		"xxx###xxx#\n" +
		"xxx#x#xxx#\n" +
		"xxx#######\n" +
		"xxxxx#xxxx\n" +
		"x#####xxxx\n" +
		"x#xxxxxxxx\n" +
		"x#xxxxxxxx\n"


	level := Level {
		hovered_tile = -1,
	}
	level_init(&level, levelTiles)
	level_coords(&level, &ctx)

	ui := Ui {
		padding      = 10,
		card_w       = 50,
		card_h       = 50,
		cards        = 5,
		card_clicked = -1,
	}
	ui_coords(&ui, &ctx)

	err: Error

	loop: for {
		frame_start := time.tick_now()

		// inputs

		event: SDL.Event
		for SDL.PollEvent(&event) {
			#partial switch event.type {
			case .WINDOWEVENT:
				if event.window.event == .SIZE_CHANGED {
					ctx.window_width, ctx.window_height = event.window.data1, event.window.data2
					level_coords(&level, &ctx)
					ui_coords(&ui, &ctx)
				}
			case .QUIT:
				return
			}
		}

		{ 	// mouse
			mouse_x, mouse_y: c.int
			btn := SDL.GetMouseState(&mouse_x, &mouse_y)

			// buttons
			switch {
			case btn & SDL.BUTTON_LMASK != 0:
				// left btn pressed
				if ui.card_clicked < 0 {
					ui_mouse_x, ui_mouse_y := mouse_x - ui.x, mouse_y - ui.y
					card_x, card_y: i32

					for i in 0 ..< ui.cards {
						inside_x := ui_mouse_x >= card_x && ui_mouse_x <= card_x + ui.card_w
						inside_y := ui_mouse_y >= card_y && ui_mouse_y <= card_y + ui.card_h

						if inside_x && inside_y {
							ui.card_clicked = i
							ui.card_click_pos = SDL.Point {
								x = ui_mouse_x,
								y = ui_mouse_y - card_y,
							}
							break
						}

						card_y += ui.card_h + ui.padding
					}
				}
			case btn & SDL.BUTTON_LMASK == 0 && ctx.mouse.btn & SDL.BUTTON_LMASK != 0:
				if ui.card_clicked >= 0 {
					if level.hovered_tile > -1 {
						tile := &level.tiles[level.hovered_tile]

						if t, ok := &tile.(TileGround);
						   ok && t.decoration == .None && t.tower == .None {
							t.tower = .Tower
						}

						level.hovered_tile = -1
					}

					ui.card_clicked = -1
				}
			}

			{ 	// hover
				x_inside_map := mouse_x >= level.x && mouse_x < level.x + level.w
				y_inside_map := mouse_y >= level.y && mouse_y < level.y + level.h

				if !x_inside_map || !y_inside_map {
					level.hovered_tile = -1
				} else if x_inside_map && y_inside_map && ui.card_clicked > -1 {
					for tile, idx in level.tiles {
						row := idx / level.rows
						col := idx - level.cols * row

						x := level.x + i32(col) * TILE_SIZE
						y := level.y + i32(row) * TILE_SIZE

						inside_x := mouse_x >= x && mouse_x < x + TILE_SIZE
						inside_y := mouse_y >= y && mouse_y < y + TILE_SIZE

						if inside_x && inside_y {
							level.hovered_tile = idx
							break
						}
					}
				}
			}

			ctx.mouse.btn = btn
			ctx.mouse.x, ctx.mouse.y = mouse_x, mouse_y
		}

		// render

		if err = render(&ctx, &level, &ui); err != nil {
			break loop
		}

		duration := time.tick_since(frame_start)
		remaining := time.Duration(FRAME_TIME_MS - time.duration_milliseconds(duration))
		ctx.frame_time = duration + remaining

		if remaining < 0 {
			continue loop
		}
		time.sleep(remaining)

		free_all(context.temp_allocator)
	}

	fmt.eprintln(error_string(err))
}
