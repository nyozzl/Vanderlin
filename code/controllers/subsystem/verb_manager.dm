/**
 * SSverb_manager, a subsystem that runs every tick and runs through its entire queue without yielding like SSinput.
 * this exists because of how the byond tick works and where user inputted verbs are put within it.
 *
 * see TICK_ORDER.md for more info on how the byond tick is structured.
 *
 * The way the MC allots its time is via TICK_LIMIT_RUNNING, it simply subtracts the cost of SendMaps (MAPTICK_LAST_INTERNAL_TICK_USAGE)
 * plus TICK_BYOND_RESERVE from the tick and uses up to that amount of time (minus the percentage of the tick used by the time it executes subsystems)
 * on subsystems running cool things like atmospherics or Life or SSInput or whatever.
 *
 * Without this subsystem, verbs are likely to cause overtime if the MC uses all of the time it has alloted for itself in the tick, and SendMaps
 * uses as much as its expected to, and an expensive verb ends up executing that tick. This is because the MC is completely blind to the cost of
 * verbs, it can't account for it at all. The only chance for verbs to not cause overtime in a tick where the MC used as much of the tick
 * as it alloted itself and where SendMaps costed as much as it was expected to is if the verb(s) take less than TICK_BYOND_RESERVE percent of
 * the tick, which isnt much. Not to mention if SendMaps takes more than 30% of the tick and the MC forces itself to take at least 70% of the
 * normal tick duration which causes ticks to naturally overrun even in the absence of verbs.
 *
 * With this subsystem, the MC can account for the cost of verbs and thus stop major overruns of ticks. This means that the most important subsystems
 * like SSinput can start at the same time they were supposed to, leading to a smoother experience for the player since ticks arent riddled with
 * minor hangs over and over again.
 */
SUBSYSTEM_DEF(verb_manager)
	name = "Verb Manager"
	wait = 1
	flags = SS_TICKER | SS_NO_INIT
	priority = FIRE_PRIORITY_DELAYED_VERBS
	runlevels = RUNLEVEL_INIT | RUNLEVELS_DEFAULT

	///list of callbacks to procs called from verbs or verblike procs that were executed when the server was overloaded and had to delay to the next tick.
	///this list is ran through every tick, and the subsystem does not yield until this queue is finished.
	var/list/datum/callback/verb_callback/verb_queue = list()
	///running average of how many verb callbacks are executed every second. used for the stat entry
	var/verbs_executed_per_second = 0

	///if TRUE we treat usr's with holders just like usr's without holders. otherwise they always execute immediately
	var/can_queue_admin_verbs = FALSE

	///if this is true all verbs immediately execute and dont queue. in case the mc is fucked or something
	var/FOR_ADMINS_IF_VERBS_FUCKED_immediately_execute_all_verbs = FALSE
	///used for subtypes to determine if they use their own stats for the stat entry
	var/use_default_stats = TRUE

	///if TRUE this will... message admins every time a verb is queued to this subsystem for the next tick with stats.
	///for obvious reasons dont make this be TRUE on the code level this is for admins to turn on
	var/message_admins_on_queue = FALSE

/**
 * queue a callback for the given verb/verblike proc and any given arguments to the specified verb subsystem, so that they process in the next tick.
 * intended to only work with verbs or verblike procs called directly from client input, use as part of TRY_QUEUE_VERB() and co.
 *
 * returns TRUE if the queuing was successful, FALSE otherwise.
 */
/proc/_queue_verb(datum/callback/verb_callback/incoming_callback, tick_check, datum/controller/subsystem/verb_manager/subsystem_to_use = SSverb_manager, ...)
	if(TICK_USAGE < tick_check \
	|| QDELETED(incoming_callback) \
	|| QDELETED(incoming_callback.object) \
	|| !ismob(usr) \
	|| QDELING(usr))
		return FALSE
	if(!istype(subsystem_to_use))
		return FALSE

	var/list/args_to_check = args.Copy()
	args_to_check.Cut(2, 4)//cut out tick_check and subsystem_to_use

	//any subsystem can use the additional arguments to refuse queuing
	if(!subsystem_to_use.can_queue_verb(arglist(args_to_check)))
		return FALSE

	return subsystem_to_use.queue_verb(incoming_callback)

/**
 * subsystem-specific check for whether a callback can be queued.
 * intended so that subsystem subtypes can verify whether
 *
 * subtypes may include additional arguments here if they need them! you just need to include them properly
 * in TRY_QUEUE_VERB() and co.
 */
/datum/controller/subsystem/verb_manager/proc/can_queue_verb(datum/callback/verb_callback/incoming_callback)
	if(usr.client?.holder && !can_queue_admin_verbs \
	|| FOR_ADMINS_IF_VERBS_FUCKED_immediately_execute_all_verbs \
	|| !initialized \
	|| !(runlevels & Master.current_runlevel))
		return FALSE
	return TRUE

/**
 * queue a callback for the given proc, so that it is invoked in the next tick.
 * intended to only work with verbs or verblike procs called directly from client input, use as part of TRY_QUEUE_VERB()
 *
 * returns TRUE if the queuing was successful, FALSE otherwise.
 */
/datum/controller/subsystem/verb_manager/proc/queue_verb(datum/callback/verb_callback/incoming_callback)
	. = FALSE //errored
	if(message_admins_on_queue)
		message_admins("[name] verb queuing: tick usage: [TICK_USAGE]%, proc: [incoming_callback.delegate], object: [incoming_callback.object], usr: [usr]")
	verb_queue += incoming_callback
	return TRUE

/datum/controller/subsystem/verb_manager/fire(resumed)
	var/executed_verbs = 0

	for(var/datum/callback/verb_callback/verb_callback as anything in verb_queue)
		if(!istype(verb_callback))
			stack_trace("non /datum/callback/verb_callback inside [name]'s verb_queue!")
			continue

		verb_callback.InvokeAsync()
		executed_verbs++

	verb_queue.Cut()
	verbs_executed_per_second = MC_AVG_SECONDS(verbs_executed_per_second, executed_verbs, wait TICKS)

/datum/controller/subsystem/verb_manager/stat_entry(msg)
	. = ..()
	if(use_default_stats)
		. += "V/S: [round(verbs_executed_per_second, 0.01)]"
