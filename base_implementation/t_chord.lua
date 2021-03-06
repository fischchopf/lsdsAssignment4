require"splay.base"
rpc = require"splay.urpc"
crypto = require"crypto"

-- addition to allow local run
if not job then
	-- may be used outside SPLAY deployments
	local utils = require("splay.utils")
	if #arg < 2 then  
		log:print("lua "..arg[0].." my_position nb_nodes")  
		os.exit()  
	else
		local pos, total = tonumber(arg[1]), tonumber(arg[2])  
		job = utils.generate_job(pos, total, 20001)  
	end
end

-- addition for debugging

debug = true
debug_level = {
	main=false,
	tman_init=false,
	active_tman=false,
	passive_tman=false,
	selectPeer=false,
	rank_view=false,
	extractMessage=false,
	merge=false,
	bootstrap_chord=false,
	extract_view=false,
	printClosestAverage=true,
	printNotOptimal=true,
	printStale=true
	}

function logD(message,level)
	if debug and debug_level[level] then
		log:print(level.."()	"..message)
	end
end

rpc.server(job.me.port)

--[[
******************************************************************************
                           PEER SAMPLING PARAMETERS
******************************************************************************
]]

c = 10
exch = 5
S = 3
H = 2
SEL = "rand"
pss_active_thread_period = 20 -- period in seconds
pss_debug = false

--[[
******************************************************************************
                     PEER SAMPLING SERVICE: DO NOT MODIFY
******************************************************************************
]]

-- variables: peer sampling
view = {}

-- utilities
function print_table(t)
	log:print("[ (size "..#t..")")
	for i=1,#t do
		log:print("  "..i.." : ".."["..t[i].peer.ip..":"..t[i].peer.port.."] - age: "..t[i].age.." - id: "..t[i].id)
	end
	log:print("]")
end

function set_of_peers_to_string(v)
	ret = ""; for i=1,#v do	ret = ret..v[i].id.." , age="..v[i].age.."; " end
	return ret
end

function print_set_of_peers(v,message)	
	if message then log:print(message) end
	log:print(set_of_peers_to_string(v))
end

function print_view(message)
	if message then log:print(message) end
	log:print("content of the view --> "..job.position..": "..set_of_peers_to_string(view))
end

-- peer sampling functions

function pss_selectPartner()
	if SEL == "rand" then return math.random(#view) end
	if SEL == "tail" then
		local ret_ind = -1 ; local ret_age = -1
		for i,p in pairs(view) do
			if (p.age > ret_age) then ret_ind = i end
		end
		assert (not (ret_ind == -1))
		return ret_ind
	end
end

function same_peer_but_different_ages(a,b)
	return a.peer.ip == b.peer.ip and a.peer.port == b.peer.port
end
function same_peer(a,b)
	return same_peer_but_different_ages(a,b) and a.age == b.age
end

function pss_selectToSend()
	-- create a new return buffer
	local toSend = {}
	-- append the local node view age 0
	table.insert(toSend,{peer={ip=job.me.ip,port=job.me.port},age=0,id=job.position})
	-- shuffle view
	view = misc.shuffle(view)
	-- move oldest H items to the end of the view
	--- 1. copy the view
	local tmp_view = misc.dup(view)
	--- 2. sort the items based on the age
	table.sort(tmp_view,function(a,b) return a.age < b.age end)
	--- 3. get the H largest aged elements from the tmp_view, remove them from the view 
	---    (we assume there are no duplicates in the view at this point!)
	---    and put them at the end of the view
	for i=(#tmp_view-H+1),#tmp_view do
		local ind = -1
		for j=1,#view do
			if same_peer(tmp_view[i],view[j]) then ind=j; break end
		end
		assert (not (ind == -1))
		elem = table.remove(view,ind)
		view[#view+1] = elem
	end

	-- append the first exch-1 elements of view to toSend
	for i=1,(exch-1) do
		toSend[#toSend+1]=view[i]
	end		

	return toSend
end

function pss_selectToKeep(received)
	if pss_debug then
		log:print("select to keep, node "..job.position)
		print_set_of_peers(received, "content of the received for "..job.position..": ")
		print_view()
	end
	-- concatenate the view and the received set of view items
	for j=1,#received do view[#view+1] = received[j] end
	
	-- remove duplicates from view
	-- note that we can't rely on sorting the table as we need its order later
	local i = 1	
	while i < #view-1 do
		for j=i+1,#view do
			if same_peer_but_different_ages(view[i],view[j]) then
				-- delete the oldest
				if view[i].age < view[j].age then 
					table.remove(view,j)
				else
					table.remove(view,i)
				end
				i = i - 1 -- we need to retest for i in case there is one more duplicate
				break
			end
		end
		i = i + 1
	end

	-- remove the min(H,#view-c) oldest items from view
	local o = math.min(H,#view-c)
	while o > 0 do
		-- brute force -- remove the oldest
		local oldest_index = -1
		local oldest_age = -1
		for i=1,#view do 
			if oldest_age < view[i].age then
				oldest_age = view[i].age
				oldest_index = i
			end
		end
		assert (not (oldest_index == -1))
		table.remove(view,oldest_index)
		o = o - 1
	end
	
	-- remove the min(S,#view-c) head items from view
	o = math.min(S,#view-c)
	while o > 0 do
		table.remove(view,1) -- not optimal
		o = o - 1
	end
	
	-- in the case there still are too many peers in the view, remove at random
	while #view > c do table.remove(view,math.random(#view)) end

	assert (#view <= c)
end 

no_passive_while_active_lock = events.lock()

function pss_passiveThread(from,buffer)
	no_passive_while_active_lock:lock()
	if pss_debug then
		print_view("passiveThread ("..job.position.."): entering")
		print_set_of_peers(buffer,"passiveThread ("..job.position.."): received from "..from)
	end
	local ret = pss_selectToSend()
	pss_selectToKeep(buffer)
	if pss_debug then
		print_view("passiveThread ("..job.position.."): after selectToKeep")
	end
	no_passive_while_active_lock:unlock()
	return ret
end

function pss_activeThread()
	-- take a lock to prevent being called as a passive thread while
	-- on an exchange with another peer
	no_passive_while_active_lock:lock()
	-- select a partner
	partner_ind = pss_selectPartner()
	partner = view[partner_ind]
	-- remove the partner from the view
	table.remove(view,partner_ind)
	-- select what to send to the partner
	buffer = pss_selectToSend()
	if pss_debug then
		print_set_of_peers(buffer,"activeThread ("..job.position.."): sending to "..partner.id)
	end
	-- send to the partner
	local ok, r = rpc.acall(partner.peer,{"pss_passiveThread", job.position, buffer},pss_active_thread_period/2)
	if ok then
		-- select what to keep etc.
		local received = r[1]
		if pss_debug then
			print_set_of_peers(received,"activeThread ("..job.position.."): received from "..partner.id)
		end
		pss_selectToKeep(received)
		if pss_debug then
			print_view("activeThread ("..job.position.."): after selectToKeep")
		end
	else
		-- peer not replying? remove it from view!
		if pss_debug then
			log:print("on peer ("..job.position..") peer "..partner.id.." did not respond -- removing it from the view")
		end
		table.remove(view,partner_ind)
	end	
	-- all ages increment
	for _,v in ipairs(view) do
		v.age = v.age + 1
	end
	-- now, allow to have an incoming passive thread request
	no_passive_while_active_lock:unlock()
end

--[[
******************************************************************************
                            THE PEER SAMPLING API
******************************************************************************
]]

pss_initialized = false
function pss_init()
	-- ideally, would perform a random walk on an existing overlay
	-- but here we emerge from the void, so let's use the Splay provided peers
	-- note that we select randomly c+1 nodes so that if we have ourself in it,
	-- we avoid using it. Ages are taken randomly in [0..c] but could be 
	-- 0 as well.
	if #job.nodes <= c then
		log:print("There are not enough nodes in the initial array from splay.")
		log:print("Use a network of at least "..(c+1).." nodes, and an initial array of type random with at least "..(c+1).." nodes")
		log:print("FATAL: exiting")
		os.exit()
	end
	if H + S > c/2 then
		log:print("Incorrect parameters H = "..H..", S = "..S..", c = "..c)
		log:print("H + S cannot be more than c/2")
		log:print("FATAL: exiting")
		os.exit()
	end
	local indexes = {}
	for i=1,#job.nodes do
		indexes[#indexes+1]=i
	end
	local selected_indexes = misc.random_pick(indexes,c+1)	
	local i = 1
	while #view < c do
		if not (selected_indexes[i] == job.position) then
			view[#view+1] = 
			{peer={ip=job.nodes[selected_indexes[i]].ip,port=job.nodes[selected_indexes[i]].port},age=0,id=selected_indexes[i]}
		end
		i=i+1
	end
	assert (#view == c)
	if pss_debug then
		print_view("initial view")
	end
	-- from that time on, we can use the view.
	pss_initialized = true	

	math.randomseed(job.position*os.time())
	-- wait for all nodes to start up (conservative)
	events.sleep(2)
	-- desynchronize the nodes
	local desync_wait = (pss_active_thread_period * math.random())
	if pss_debug then
		log:print("waiting for "..desync_wait.." to desynchronize")
	end
	events.sleep(desync_wait)  

	for i =1, 4 do
		pss_activeThread()
		events.sleep(pss_active_thread_period / 4)
	end
	t1 = events.periodic(pss_activeThread,pss_active_thread_period)
end  

function pss_getPeer()
	if pss_initialized == false then
		log:print("Call to pss_getPeer() while the PSS is not initialized:")
		log:print("wait for some time before using the PSS!")
		log:print("FATAL. Exiting")
	end
	if #view == 0 then
		return nil
	end
	return view[math.random(#view)]
end


--[[
******************************************************************************
                           CLASSICAL CHORD SERVICE
******************************************************************************
]]--


n = {}
m = 32
num_successors = 8
tchord_debug = false
predecessor = nil
successors = {}
finger = {}




--Getters and Setters for predecessor and successor:
function get_successor()
	return finger[1].node
end


function get_predecessor()
	return predecessor
end


function set_successor(node)
	finger[1].node = node
	if chord_debug then
		log:print("new successor = "..finger[1].node.id)
	end
end


function set_predecessor(node)
	predecessor = node
	if chord_debug then
		log:print("new predecessor = "..predecessor.id)
	end
end

--Verifies if ID is inside (low, high] (all numbers):
function does_belong_open_closed(id, low, high)
	if low < high then
	  return (id > low and id <= high)
	else
	  return (id > low or id <= high)
	end
end

--Verifies if ID is inside [low, high) (all numbers):
function does_belong_closed_open(id, low, high)
	if low < high then
	  return (id >= low and id < high)
	else
	  return (id >= low or id < high)
	end
end

--Verifies if ID is inside [low, high) (all numbers):
function does_belong_open_open(id, low, high)
	if low < high then
	  return (id > low and id < high)
	else
	  return (id > low or id < high)
	end
end

--Returns the finger with bigger i which is preceding a given ID
function closest_preceding_finger(id)
	--from m to 1:
	for i = m,1,-1 do
		--if the finger is between the node and the given ID:
		if does_belong_open_open(finger[i].node.id, n.id, id) then
			--return this finger:
			return finger[i].node
		end
	end
end

--Finds the predecessor of a given ID (number):
function find_predecessor(id)
	--Starts with itself:
	local node = n
	local node_succ = get_successor()
	--Initializes counter:
	local i = 0
	--Iterates while id does not belong to (node, node_succ]:
	while (not does_belong_open_closed(id, node.id, node_succ.id)) do
		--the successor substitutes the current node for the next iteration:
		node = rpc.call(node, {"closest_preceding_finger", id})
		--the successor's successor is the new successor in the next iteration:
		node_succ = rpc.call(node, "get_successor")
		--Increments counter:
		i = i + 1
	end
	return node, i
end

--Finds the successor of a given ID (number):
function find_successor(id)
	--Finds the predecessor:
	local node = find_predecessor(id)
	--Gets the successor of the resulting node:
	local node_succ = rpc.call(node, "get_successor")
	return node_succ
end

--Initializes the neighbors when a node is joining the Chord network:
function init_finger_table(node)
	--the first finger node is calculated by 'node' as the successor of finger1.start:
	finger[1].node = rpc.call(node, {"find_successor", finger[1].start})
	--for the other fingers:
	for i = 1, m-1 do
		--if finger[i].start is between the node's ID and the last calculated finger:
		if does_belong_closed_open(finger[i+1].start, n.id, finger[i].node.id) then
			--this finger is the same as last one:
			finger[i+1].node = finger[i].node
		else --if not,
			--finds successor with the help of 'node':
			finger[i+1].node = rpc.call(node, {"find_successor", finger[i + 1].start})
		end
	end
end

function update_finger_table(s, i)
	--local low = n.id --I REMOVED THIS, WHY IS THIS WAY IN THE ALGO?
	local low = finger[i].start --I ADDED THIS
	local high = finger[i].node.id --I ADDED THIS
	if low ~= high then --I ADDED THIS
		--if the node to be inserted is closer to finger[i].start than finger[i].node:
		if does_belong_closed_open(s.id, low, high) then
			--replaces the finger:
			finger[i].node = s
			--looks for the predecessor of this node:
			p = get_predecessor()
			--and updates also the node's predecessor if needed:
			rpc.call(p, {"update_finger_table", s, i})
		end
	end --I ADDED THIS
end


function update_others()
	--updates its successor of it being the new predecessor:
	rpc.call(get_successor(), {"set_predecessor", n})
	--updates the finger tables:
	for i = 1, m do
		local id = (n.id + 1 - 2^(i-1)) % 2^m --I ADDED THIS +1
		--finds the predecessor of n - 2^(i-1) (does backwards the calculation of start):
		local p = find_predecessor(id)
		--updates the finger table of this node:
		rpc.call(p, {"update_finger_table", n, i})
	end
end

--Joins the Chord network:
function join(node)
	--If a node is given as input:
	if node then
		--Initializes the neighbors through this node:
		init_finger_table(node)
		set_predecessor(rpc.call(get_successor(), "get_predecessor"))
		update_others()
	else
		--If not, you are alone in the network, so you are your own predecessor, successor and fingers:
		for i = 1, m do
			finger[i].node = n
		end
		set_predecessor(n)
	end
end

--Initializes IP, port, ID in variable n
function init_chord()
	predecessor = nil
	successors = {}
	for i = 1, m do
		finger[i] = {
			start = (n.id + 2^(i-1))%2^m
		}
	end

end


function print_chord()
	log:print("local_node: "..n.id)
	log:print("predecessor: "..predecessor.id)

	for i = 1, #successors do
		log:print("successor "..i.." : "..successors[i].id)
	end

	for i = 1, #finger do
		log:print("finger "..i..": start:"..finger[i].start..", node: "..finger[i].node.id)
	end
end

-- computes the sha1 hash of a node and converts the hex output into a number
-- when not using multiples of 4 for m this results in a smaller hash space than expected
function compute_hash(node)
	local o = (node.ip..":"..tostring(node.port))
	return tonumber(string.sub(crypto.evp.new("sha1"):digest(o), 1, m / 4), 16)
end

--[[
******************************************************************************
                         T-MAN
******************************************************************************
]]


tman_view = {}
tman_active_thread_period = 20
tman_cycle = 0

tman_passive_active_lock = events.lock()

function active_tman()
	tman_passive_active_lock:lock()
	tman_cycle = tman_cycle +1
	logD("selecting a peer from the tman_view","active_tman")
	local p = selectPeer(tman_view)
	logD("selected peer ID="..p.id,"active_tman")
	logD("Extracting message","active_tman")
	local message = extractMessage(tman_view,p)
	logD("Sending message","active_tman")
	local ok, r = rpc.acall(p, {"passive_tman", message, n},tman_active_thread_period/2)
	if ok then
		logD("merging answer into view","active_tman")
		tman_view = merge(r[1],tman_view)
	else
		log:print("Tman exchange failed! error message:"..r)
	end
	--events.thread(evaluation_thread)
	tman_passive_active_lock:unlock()
end

function passive_tman(message,q)
	tman_passive_active_lock:lock()
	logD("Extracting message","passive_tman")
	local answer = extractMessage(tman_view,q)
	logD("Merging View and recieved message","passive_tman")
	tman_view = merge(message,tman_view)
	tman_passive_active_lock:unlock()
	logD("Returning answer message","passive_tman")
	return answer
end

--ranks the nodes in S based on distance to n and returns a random node from the nearest m
function selectPeer(S)
	logD("ranking the tman_view","selectPeer")
	local temp = rank_view(S,n.id)
	logD("returning a random peer from the first "..num_successors,"selectPeer")
	return temp[math.random(num_successors)]
end

--ranks the nodes in S based on distance to q and returns the nearest m
function extractMessage(S,q)
	logD("ranking the tman_view in relation to q ID="..q.id,"extractMessage")
	local sorted = rank_view(S,q.id)
	local message = {}
	logD("selecting the nearest "..num_successors.." peers","extractMessage")
	for i=1,num_successors do
		table.insert(message,sorted[i])
	end
	logD("Returning the message:","extractMessage")
	if debug and debug_level["extractMessage"] then
		print_tman_table(message)
	end
	return message
end

--returns the union of the sets S1 and S2
function merge(S1, S2)
	logD("Merging the tables S1 and S2","merge")
	if debug and debug_level["merge"] then
		log:print("S1:")
		print_tman_table(S1)
		log:print("S2:")
		print_tman_table(S2)
	end
	logD("Iterating over S2","merge")
	for i=1, #S2 do
		logD("Check if item "..i.." is not in S1","merge")
		if not table.contains(S1, S2[i]) then
			logD("Inserting item"..i.." into S1","merge")
			table.insert(S1,S2[i])
		end
	end
	logD("Returning the merged table:","merge")
	if debug and debug_level["merge"] then
		print_tman_table(S1)
	end
	return S1
end

tman_ranking_lock = events.lock()

--ranks the nodes in S based on the distace to r
function rank_view(S,r)
	tman_ranking_lock:lock()
	ranking_base = r
	logD("View to be ranked in relation to ID"..ranking_base,"rank_view")
	if debug and debug_level["rank_view"] then
		print_tman_table(S)
	end
	logD("createing copy of view","rank_view")
	local temp = misc.dup(S)
	logD("sorting the copy","rank_view")
	table.sort(temp,function(a,b) return math.min(math.abs(a.id-ranking_base),((2^m)-math.abs(a.id-ranking_base))) < math.min(math.abs(b.id-ranking_base),((2^m)-math.abs(b.id-ranking_base))) end)
	logD("Sorted view:","rank_view")
	if debug and debug_level["rank_view"] then
		print_tman_table(temp)
	end
	tman_ranking_lock:unlock()
	logD("returning sorted view","rank_view")
	return temp
end


function table.contains(table, element)
 	for _, value in pairs(table) do
		if value.id == element.id then
		return true
		end
	end
 	return false
end




--[[
******************************************************************************
                         T-MAN -- API
******************************************************************************
]]

function tman_init()
	logD("Generating my ID and saving it into n","tman_init")
	n = {ip=job.me.ip,port=job.me.port,id=compute_hash(job.me)}
	log:print("My ID="..n.id)
	logD("Initialize tman view","tman_init")
	logD("Adding myself","tman_init")
	table.insert(tman_view,n)
	logD("Copying the pss view, changing the datastructure and calculating chord IDs","tman_init")
	for i=1,#view do
		table.insert(tman_view,{ip=view[i].peer.ip,port=view[i].peer.port,id=compute_hash(view[i].peer)})
	end
	logD("Initial tman view:","tman_init")
	if debug and debug_level["tman_init"] then
		print_tman_table(tman_view)
	end
	log:print("T-man initialized\nWaitng for other nodes to initialize t-man")
	events.sleep(10)
	log:print("Starting periodic active tman thread")
	active_thread_tman = events.periodic(active_tman,tman_active_thread_period)
end

function bootstrap_chord(v)
	logD("extracting chord links from tman view","bootstrap_chord")
	predecessor, successors, finger = extract_view(v)
	if debug and debug_level["bootstrap_chord"] then
		print_chord()
	end
end

function extract_view(view)
	local temp = misc.dup(view)
	logD("Sorting the tman view","extract_view")
	table.sort(temp,function(a,b) return ((a.id-n.id)%(2^m)) < ((b.id-n.id)%(2^m)) end)
	if debug and debug_level["extract_view"] then
		print_tman_table(temp)
	end
	local temp_predecessor = nil
	local temp_sucessors = {}
	local temp_fingers = {}
	logD("extracting predecessor","extract_view")
	temp_predecessor = temp[#temp]
	logD("extracting successors","extract_view")
	for i=2, num_successors+1 do
		table.insert(temp_sucessors, temp[i])
	end
	logD("generating finger starts","extract_view")
	for i = 1, m do
		temp_fingers[i] = {
			start = (n.id + 2^(i-1))%2^m
		}
	end
	logD("extracting fingers","extract_view")
	for i=1, #temp_fingers do
		for j=1, #temp do
			if temp_fingers[i].start <= temp[j].id then
				temp_fingers[i].node = temp[j]
				break
			end
		end
	end
	return temp_predecessor, temp_sucessors, temp_fingers
end

--[[
******************************************************************************
                         UTILITIES/EVALUATION
******************************************************************************
]]
--runs the different evaluation functions in a separate thread
function evaluation_thread()
	--logD("NotOptimal: cycle "..tman_cycle.." number "..compareViewsNumber(tman_view,job_nodes_to_view()),"printNotOptimal")
	logD("ClosestAverage: cycle "..tman_cycle.." average "..average_closest_tman(),"printClosestAverage")
end

--counts the number of difference between two views
function compareViewsNumber(v1, v2)
	local temp_predecessor, temp_sucessors, temp_fingers = extract_view(v1)
	local predecessor, sucessors, fingers = extract_view(v2)
	local count = 0
	if not (temp_predecessor.id == predecessor.id) then
		count = count + 1
	end
	for i=1, #temp_sucessors do
		if not (temp_sucessors[i].id == sucessors[i].id) then
			count = count + 1
		end
	end
	for i=1, #temp_fingers do
		if not (temp_fingers[i].node.id == fingers[i].node.id) then
			count = count + 1
		end
	end
	return count
end

--counts the number of stale references
function staleReferenceNumber()
	churn_cycle = churn_cycle +1
	local count = 0
	--logD("Pinging predecessor ID="..predecessor.id,"printStale")
	if not rpc.ping(predecessor,5) then
		count = count + 1
	end
	for i=1, #successors do
		--logD("Pinging successor "..i.."ID="..successors[i].id, "printStale")
		if not rpc.ping(successors[i],5) then
			count = count + 1
		end
	end
	for i=1, #finger do
		--logD("Pinging finger "..i.." ID="..finger[i].node.id, "printStale")
		if not rpc.ping(finger[i].node,5) then
			count = count + 1
		end
	end
	logD("StaleReferences: cycle "..churn_cycle.." count "..count,"printStale")
end

--returns all active nodes in the network in the same datastructure as the tman view
function job_nodes_to_view()
	local temp = {}
	for i=1, #job.nodes do
		if rpc.ping(job.nodes[i],5) then
			table.insert(temp,{ip=job.nodes[i].ip,port=job.nodes[i].port,id=compute_hash(job.nodes[i])})
		end
	end
	return temp
end


function print_tman_table(t)
	log:print("[ (size "..#t..")")
	for i=1,#t do
		log:print("  "..i.." : ".."["..t[i].ip..":"..t[i].port.."] - id: "..t[i].id)
	end
	log:print("]")
end

--calcuates the average of the closest items in the tman viev
function average_closest_tman()
	local temp = extractMessage(tman_view,n)
	local sum = 0
	for i=1, num_successors do
	sum = sum + math.min(math.abs(temp[i].id-n.id),((2^m)-math.abs(temp[i].id-n.id)))
	end
	return sum/num_successors
end

--calculates the distance between two nodes
function distance(a,b)
	return math.min(math.abs(a.id-b.id),((2^m)-math.abs(a.id-b.id)))
end

--returns true if a node succeeds the other (see the chord paper for definton)
function is_follower(a,b)
	if ((a-b+(2^m))%(2^m)) < (2^(m-1)) then
		return true
	else
		return false
	end
end

--launches a search querry
function searchQuerry()
	countHops(find_predecessor(compute_hash({ip=tostring(math.random()),port=math.random()})).id, 0)
end

-- counts the hops needet to reach another node in the ring
function countHops(id, index)
  if id == n.id then
    log:print("hops="..index)
  else
    rpc.acall(closest_preceding_finger((id+1)%(2^m)), {'countHops', id, (index +1)},2)
  end
end

--[[
******************************************************************************
                         THIS IS WHERE YOUR CODE GOES
******************************************************************************
]]

function terminator()
	log:print("node "..job.position.." will end in 10min")
	events.sleep(1200)
	log:print("Terminator Exiting")
	os.exit()
end


function main ()
	events.thread(terminator)
	log:print("Initializing pss")
	pss_init()
	while not pss_initialized do
		events.sleep(1)
	end
	log:print("pss initialized")
	if debug and debug_level["main"] then
		print_table(view)
	end
	log:print("Initializing tman")
	tman_init()
	log:print("Waiting for tman to construct overlay")
	events.sleep(600)
	log:print("stoping tman")
	events.kill(active_thread_tman)
	log:print("bootstraping chord")
	bootstrap_chord(job_nodes_to_view())
	--bootstrap_chord(tman_view)
	if not (debug and debug_level["bootstrap_chord"]) then
		print_chord()
	end
	log:print("waiting for all nodes to bootstrap")
	events.sleep(120)
	churn_cycle = 0
	eval_thread = events.periodic(staleReferenceNumber,20)
end

events.thread(main)  
events.loop()
