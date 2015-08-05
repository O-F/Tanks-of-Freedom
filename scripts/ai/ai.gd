var root
var positions
var pathfinding
var abstract_map
var action_controller
const CLOSE_RANGE = 6
const LOOKUP_RANGE = 20
var actions
var wandering
var offensive
var current_player_ap = 0
var current_player

const SPAWN_LIMIT = 12
const DEBUG =true
var terrain
var units
var buildings
var enemy_bunker

var action_builder
var cost_grid

var behaviour_normal
var behaviour_destroyer
var behaviour_explorer
var behaviours = []

var player_behaviours

var finished_loop = true
var units_done = false
var processed_units = {}
var camera_ready = false

func _init(controller, astar_pathfinding, map, action_controller_object):
	self.root = action_controller_object.root_node
	positions = controller
	pathfinding = astar_pathfinding
	abstract_map = self.root.dependency_container.abstract_map
	action_controller = action_controller_object
	cost_grid = preload('pathfinding/cost_grid.gd').new(abstract_map)
	actions = preload('actions.gd').new()

	self.action_builder = preload('actions/action_builder.gd').new(action_controller, abstract_map, positions)
	self.wandering = preload('res://scripts/ai/wandering.gd').new(abstract_map, actions, pathfinding, self.action_builder, positions)
	self.offensive = preload('res://scripts/ai/offensive.gd').new(abstract_map, actions, pathfinding, self.action_builder, positions)
	behaviour_normal = preload('behaviours/normal.gd').new()
	behaviour_destroyer = preload('behaviours/destroyer.gd').new()
	behaviour_explorer = preload('behaviours/explorer.gd').new()
	behaviours = [behaviour_destroyer]

	player_behaviours = [behaviour_destroyer, behaviour_destroyer]

func select_behaviour_type(player):
	player_behaviours[player] = behaviours[floor(rand_range(0, behaviours.size()))]
	#print('SELECTED BEHAVIOUR FOR PLAYER: ', player, ' IS ', rand)

func gather_available_actions(player_ap):
	current_player = action_controller.current_player
	current_player_ap = player_ap

	if self.finished_loop:
		self.actions.clear()
		# refreshing unit and building data
		self.positions.refresh_units()
		#positions.refresh_buildings()
		#if DEBUG:
		#	print('DEBUG -------------------- ')
		self.buildings = self.positions.get_player_buildings(current_player)
		self.units     = self.positions.get_player_units(current_player)
		self.terrain   = self.positions.get_terrain_obstacles()

		self.__gather_building_data(buildings, units)

		self.finished_loop = false
		return true

	if not self.units_done:
		self.__gather_unit_data(buildings, units, terrain)
		return true

	if not self.camera_ready:
		var best_action = self.actions.get_best_action()
		self.camera_ready = true
		if best_action != null:
			self.action_controller.move_camera_to_point(best_action.unit.get_pos_map())
		return true

	self.put_on_cooldown()
	self.finished_loop = true
	self.units_done = false
	self.processed_units.clear()
	self.camera_ready = false
	return actions.execute_best_action()

func put_on_cooldown():
	var ai_timer = self.root.ai_timer
	ai_timer.is_on_cooldown = true
	self.root.dependency_container.timers.set_timeout(ai_timer.INTERVAL, self, "remove_cooldown")

func remove_cooldown():
	self.root.ai_timer.is_on_cooldown = false

func get_target_buildings():
	var buildings = []
	var enemy_buildings
	var unclaimed
	if self.current_player == 0:
		buildings = self.positions.get_player_buildings(1)
	else:
		buildings = self.positions.get_player_buildings(0)
	unclaimed = self.positions.get_unclaimed_buildings()
	for building_position in unclaimed:
		buildings[building_position] = unclaimed[building_position]
	return buildings

func __gather_unit_data(own_buildings, own_units, terrain):
	if own_units.size() == 0:
		self.units_done = true
		return

	self.pathfinding.set_cost_grid(cost_grid.prepare_cost_maps(own_buildings, own_units))
	self.wandering.add_elemental_trails()

	var unit
	var position
	var destinations

	for pos in own_units:
		unit = own_units[pos]
		if self.processed_units.has(unit.get_instance_ID()):
			continue

		self.processed_units[unit.get_instance_ID()] = true
		if unit.get_ap() > 1:
			position = unit.get_pos_map()

			destinations = []
			destinations = self.__gather_unit_destinations(position, current_player)
			destinations = destinations + __gather_buildings_destinations(position, current_player)
			if destinations.size() == 0 && current_player_ap > 5:
				#self.wandering.wander(unit, self.units)
				self.offensive.push_front(unit, self.get_target_buildings(), self.units)
			else:
				#TODO - calculate data in units groups
				for destination in destinations:
					self.__add_action(unit, destination, own_units)
			return
	self.units_done = true

func __gather_unit_destinations(position, current_player, tiles_ranges=self.positions.tiles_lookup_ranges):
	var destinations = []
	var nearby_tiles
	for lookup_range in tiles_ranges:
		nearby_tiles = self.positions.get_nearby_tiles(position, lookup_range)
		destinations = destinations + self.positions.get_nearby_enemies(nearby_tiles, current_player)

		if destinations.size() > 0:
			#print('RANGE OF UNIT LOOKUP', lookup_range)
			return destinations

	return destinations

#TODO this method will be rewritten to use building cache
func __gather_buildings_destinations(position, current_player):
	var destinations = []
	var nearby_tiles
	for lookup_range in self.positions.tiles_lookup_ranges:
		nearby_tiles = self.positions.get_nearby_tiles(position, lookup_range)
		destinations = self.positions.get_nearby_enemy_buldings(nearby_tiles, current_player)
		destinations = destinations + positions.get_nearby_empty_buldings(nearby_tiles)

		if destinations.size() > 0:
			#print('RANGE OF BUILDING LOOKUP', lookup_range)
			return destinations

	return destinations

func __gather_building_data(own_buildings, own_units):
	if own_units.size() >= SPAWN_LIMIT:
		return
	#var buildings = positions.get_player_buildings(current_player)
	var building
	var enemy_units
	for pos in own_buildings:
		building = own_buildings[pos]

		if (building.type == 4): # skip tower
			continue

		enemy_units = self.__gather_unit_destinations(building.get_pos_map(), current_player, positions.tiles_building_lookup_ranges)
		self.__add_building_action(building, enemy_units, own_units)


func __add_action(unit, destination, own_units):
	var path = pathfinding.pathSearch(unit.get_pos_map(), destination.get_pos_map(), own_units) #todo move cache temporary invalidation before loop

	var action_type = self.action_builder.ACTION_MOVE
	var hiccup = false

	if path.size() == 0:
		return

	# jakies solidne WTF?
	if (unit.get_pos_map() == path[0]):
		path.remove(0)

	if path.size() > 0:
		# skip if this can be capture move and building cannot be captured
		var unit_ap_cost = 0
		var tile_ap = 0
		# verify action_type
		var next_tile = abstract_map.get_field(path[0])

		if (next_tile.object != null):
			if(next_tile.object.group == 'building'):
				if unit.can_capture_building(next_tile.object):
					action_type = self.action_builder.ACTION_CAPTURE
				else:
					return # if cannot capture he canot move
			elif next_tile.object.group == 'unit':
				if unit.can_attack_unit_type(next_tile.object) && unit.can_attack():
					action_type = self.action_builder.ACTION_ATTACK
				else:
					return
		else:
			var from = self.abstract_map.get_field(unit.get_pos_map())
			# todo - check why this still counts as action
			if not from.object:
				return

			var to = self.abstract_map.get_field(path[0])
			if not action_controller.movement_controller.can_move(from, to):
				return

			action_type = self.action_builder.ACTION_MOVE
			unit_ap_cost = abstract_map.calculate_path_cost(unit, path)
			var last_tile = abstract_map.get_field(path[path.size() - 1])
			if (last_tile.object != null):
				if (last_tile.object.group == 'building'):
					if (unit.can_capture_building(last_tile.object)):
						action_type = self.action_builder.ACTION_MOVE_TO_CAPTURE

				elif(last_tile.object.group == 'unit'):
					if (unit.can_attack_unit_type(last_tile.object)):
						action_type = self.action_builder.ACTION_MOVE_TO_ATTACK

			# checking for movement hiccup (only for movement)
			hiccup = unit.check_hiccup(path[0])


		var score = unit.estimate_action(action_type, path.size(), unit_ap_cost, hiccup, player_behaviours)
		var action = self.action_builder.create(action_type, unit, path)
		actions.append_action(action, score)
		#if DEBUG:
		#	print("DEBUG : ", action.get_action_name(), " score: ", score, " ap: ", unit_ap_cost," pos: ",unit.get_pos_map()," path: ", path)

func __add_building_action(building, enemy_units_nearby, own_units):

	var action_type = self.action_builder.ACTION_SPAWN
	var spawn_point = abstract_map.get_field(building.spawn_point)
	if (spawn_point.object == null && building.get_required_ap() <= current_player_ap):
		var score = building.estimate_action(action_type, enemy_units_nearby, own_units, current_player_ap, SPAWN_LIMIT)
		var claim_modifier = 15 - (action_controller.turn - building.turn_claimed)
		if claim_modifier < 0:
			claim_modifier = 0

		if building.type == building.TYPE_BARRACKS:
			score = score + claim_modifier

		var action = self.action_builder.create(action_type, building, null)
		actions.append_action(action, score)
		#if DEBUG:
		#	print("DEBUG : ", action.get_action_name(), " score: ", score, " ap: ", building.get_required_ap())



