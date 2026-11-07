class_name RadioNetHost
extends RefCounted

## Wires dot-radio's schedule replication onto a [DotNetManager]: the server side broadcasts [RadioScheduleMessage] from its tick and greets each new peer, the client side hands received payloads to [method DotRadioClient.apply_wire]. Register before the manager starts (it seals the message table). Audio still downloads over HTTP.

var replicator: DotRadioReplicator
var client: DotRadioClient
var manager: DotNetManager

## Schedules this client applied, and payloads it refused.
var applied := 0
var refused := 0


## Server: call [method update] from the tick, [method greet] from the peer-connected hook.
static func serve(p_manager: DotNetManager, station: DotRadioStation) -> RadioNetHost:
	var h := RadioNetHost.new()
	h.manager = p_manager
	h.replicator = DotRadioReplicator.new(station)
	h.replicator.broadcast = func(bytes: PackedByteArray) -> void: p_manager.send(RadioScheduleMessage.make(bytes), 0)
	_register(p_manager)
	return h


## Client: stops the radio client polling `/now`; it follows the pushed schedule.
static func follow(p_manager: DotNetManager, p_client: DotRadioClient) -> RadioNetHost:
	var h := RadioNetHost.new()
	h.manager = p_manager
	h.client = p_client
	p_client.poll_schedule = false
	_register(p_manager)
	p_manager.messages.on(RadioScheduleMessage.TYPE, h._on_message)
	return h


func update() -> bool:
	return replicator != null and replicator.update()


func greet(peer_id: int) -> void:
	if replicator != null:
		manager.send(RadioScheduleMessage.make(replicator.snapshot()), peer_id)


static func _register(m: DotNetManager) -> void:
	m.messages.register(RadioScheduleMessage.TYPE, RadioScheduleMessage,
		DotNetMessage.Delivery.RELIABLE, DotNetMessage.Direction.TO_CLIENT)


func _on_message(message: DotNetMessage) -> void:
	if client != null and client.apply_wire((message as RadioScheduleMessage).payload).ok:
		applied += 1
	else:
		refused += 1
