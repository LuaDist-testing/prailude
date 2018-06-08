local Peer = require "prailude.peer"
local log = require "prailude.log"
local Bus = require "prailude.bus"
local config = require "prailude.config"
local Timer = require "prailude.util.timer"
local DB = require "prailude.db"
local Frontier = require "prailude.frontier"
local Account = require "prailude.account"
local Message = require "prailude.message"
local Block = require "prailude.block"
local BlockWalker = require "prailude.blockwalker"
local Vote = require "prailude.vote"
local Util = require "prailude.util"
local Parser = require "prailude.util.parser"

local uv = require "luv"
local mm = require "mm"
local coroutine = require "prailude.util.coroutine"
--local bytes_to_hex = require "prailude.util".bytes_to_hex
local Nanonet = {}

local tdiff = function(t0, t1)
  local diff = t1-t0
  return ("%.0fm%.0fs"):format(math.floor(diff/60), diff % 60)
end

local function keepalive()
  --bootstrap
  
  local function parse_bootstrap_peer(peer_string)
    local peer_name, peer_port
    if type(peer_string) == "string" then
      peer_name, peer_port = peer_string:match("^(.*):(%d+)$")
      if not peer_name then
        peer_name, peer_port = peer_string, 7075
      else
        peer_port = tonumber(peer_port)
      end
    else
      peer_name, peer_port = peer_string[1] or peer_string.name or peer_string.host, peer_string[2] or peer_string.port
    end
    return peer_name, peer_port
  end
  
  Bus.sub("run", function()
    local keepalive_msg = Message.new("keepalive", {peers = {}})
    for _, preconfd_peer in pairs(config.node.preconfigured_peers) do
      local peer_name, peer_port = parse_bootstrap_peer(preconfd_peer)
      local addrinfo = uv.getaddrinfo(peer_name, nil, {socktype="dgram", protocol="packet"})
      for _, addrinfo_entry in ipairs(addrinfo) do
        local peer = Peer.get(addrinfo_entry.addr, peer_port)
        peer:send(keepalive_msg)
      end
    end
  end)
  
  --keepalive parsing and response
  Bus.sub("message:receive:keepalive", function(ok, msg, peer)
    if not ok then
      return log:warn("nanonet: message:receive:keepalive failed from peer %s: %s", peer, msg)
    end
    peer:update_keepalive(msg)
    if Peer.get_active_count() < config.node.max_peers then
      local inpeer
      local now = os.time()
      local keepalive_cutoff = now - Peer.keepalive_interval
      if (peer.last_keepalive_sent or 0) < keepalive_cutoff then
        peer:send(Message.new("keepalive", {peers = Peer.get8(peer)}))
      end
      for _, peer_data in ipairs(msg.peers) do
        inpeer = Peer.get(peer_data)
        if (inpeer.last_keepalive_sent or 0) < keepalive_cutoff then
          inpeer:send(Message.new("keepalive", {peers = Peer.get8(inpeer)}))
        end
      end
    end
  end)
  
  --periodic keepalive checks
  Timer.interval(Peer.keepalive_interval * 1000, function()
    local ping_these_peers = Peer.get_active_needing_keepalive()
    for _, peer in pairs(ping_these_peers) do
      peer:send(Message.new("keepalive", {peers = Peer.get8(peer)}))
    end
  end)
end


local function handle_blocks()
  local function check_block(block, peer)
    local ok, err = block:verify_PoW()
    if not ok then
      log:debug("server: got block that failed verification (%s) from %s", err, tostring(peer))
    else
      return true
    end
  end
  Bus.sub("message:receive:publish", function(ok, msg, peer)
    if not ok then
      return log:warn("nanonet: message:receive:publish from %s failed: %s", peer, msg)
    end
    local block = Block.unpack(msg.block_type, msg.block)
    check_block(block, peer)
  end)
  Bus.sub("message:receive:confirm_req", function(ok, msg, peer)
    if not ok then
      return log:warn("nanonet: message:receive:confirm_req from %s failed: %s", peer, msg)
    end
    local block = Block.unpack(msg.block_type, msg.block)
    check_block(block, peer)
  end)
  Bus.sub("message:receive:confirm_ack", function(ok, msg, peer)
    if not ok then
      return log:warn("nanonet: message:receive:confirm_ack from %s failed: %s", peer, msg)
    end
    coroutine.wrap(function()
      local vote = Vote.new(msg)
      if vote:verify() then
        Bus.pub("vote:receive", vote, peer)
        --log:debug("legit vote from %s", peer)
      --else
      --  log:warn("invalid vote from %s acct %s block %s, mate!!", peer, vote.account, bytes_to_hex(vote.block.hash))
      end
    end)()
  end)
end

function Nanonet.initialize()
  --local initial_peers = {}
  keepalive()
  handle_blocks()
end

function Nanonet.bootstrap()
  local gettime = require "prailude.util.lowlevel".gettime
  local maybe_interrupt; do
    local clock = os.clock
    maybe_interrupt = function(n_max)
      local tw0 = clock()
      local n = 0
      n_max = n_max or 5
      return function()
        n = n+1
        if n > n_max then
          n=0
          if clock() - tw0 > 0.5 then
            Timer.delay(10)
            tw0=clock()
          end
        end
      end
    end
  end
  
  local coro = coroutine.create(function()
    --let's gather some peers first. 50 active peers should be enough
    
    local fetch, import, verify = true, true, true
    
    if fetch then
      log:debug("bootstrap: preparing database...")
      Frontier.clear_bootstrap()
      Block.clear_bootstrap()
    end
    
    local t0 = gettime()
    local t1, t2
    
    if fetch then
      local min_count = 100
      log:debug("bootstrap: connecting to peers...")
      while Peer.get_active_count() < min_count do
        log:debug("bootstrap: gathering at least %i peers, have %i so far", min_count, Peer.get_active_count())
        Timer.delay(1000)
      end
      t1 = gettime()
      log:debug("bootstrap: fetching frontiers... this should take a few minutes...")
      Nanonet.fetch_frontiers(3)
      t2=gettime()
      log:debug("bootstrap: frontiers fetched in %s. finding already synced frontiers...", tdiff(t1, t2))
      local already_synced = Frontier.delete_synced_frontiers()
      log:debug("bootstrap: finished in %s. need to sync %i frontiers (%i already synced)", tdiff(t2, gettime()), Frontier.get_size(), already_synced)
      t1 = gettime()
      log:debug("bootstrap: gathering blocks... this should take 20-50 minutes...")
      Nanonet.bulk_pull_accounts()
      print("bootstrap: finished gathering blocks in %s", tdiff(t1, gettime()))
    end
    
    if import then
      local need_to_import = Block.count_bootstrapped()
      log:debug("bootstrap: importing %i blocks... this should take a few minutes...", need_to_import)
      local ti0 = gettime()
      
      local imported, last_imported, t_diff, last_timestamp
      local watcher = Timer.interval(1000, function()
        log:debug("bootstrap: t: %.3f imported %i of %i blocks [%3.2f%%], (%.0fblocks/sec)", last_timestamp or 0, imported, need_to_import, (imported/need_to_import)*100, last_imported/t_diff)
      end)
      
      Block.import_unverified_bootstrap_blocks(maybe_interrupt(1000), function(n, t, timestamp)
        --progress handler
        imported = (imported or 0) + n
        last_imported = n
        t_diff = t
        last_timestamp = timestamp
      end)
      Timer.cancel(watcher)
      log:debug("bootstrap: imported %i blocks in %s", need_to_import, tdiff(ti0, gettime()))
      
      --Block.clear_bootstrap()
    end
    
    if verify then
      
      local walker = BlockWalker.new {
        start = "genesis",
        direction = "frontier",
        interrupt = maybe_interrupt(20)
      }
      
      local watcher = Timer.interval(1000, function()
        --log:debug("bootstrap: ts: %i, verifying; %i \"already valid\", %i verified, %i failed, %i retries. actual ledger-valid: %i, queue: %s",
        --os.time(), walker.stats.already_verified, walker.stats.verified, walker.stats.failed, walker.stats.retry, Block.count_valid("ledger"), tostring(walker.unvisited:count()))
        print(("%i, %i, %i, %i, %i, %i"):format(os.time(), walker.stats.verified, Block.count_valid("ledger"), walker.stats.failed, walker.stats.retry, walker.unvisited:count()))
      end)
      
      
      DB.db():exec("delete from accounts")
      DB.db():exec("update blocks set valid = 2 where valid > 2")
      
      assert(walker:walk())
      
      Timer.cancel(watcher)
      log:debug("bootstrap: verifying finished. %i already valid, %i verified, %i failed, %i retries. actual ledger-valid: %s",
        walker.stats.already_verified, walker.stats.verified, walker.stats.failed, walker.stats.retry, Block.count_valid("ledger"))
      
    end
    
    local t3 = os.time()
    log:debug("Bootstrap took %s", tdiff(t0, t3))
    
  end)
  return coroutine.resume(coro)
end

function Nanonet.bulk_pull_accounts()
  --print("now bulk_pull some accounts", #frontier)
  local min_speed = 3 --blocks/sec
  local active_peers = {}
  local frontier_size = Frontier.get_size()
  local total_blocks_fetched, total_accounts_fetched, total_accounts_failed = 0, 0, 0
  
  local account_frontier_score_delta = 1/frontier_size
  
  local source = Util.BatchSource(function(n)
    local batch = Frontier.get_range(50000, n)
    if #batch > 0 then
      return batch
    else
      return nil
    end
  end)
  
  local sink = Util.BatchSink {
    batch_size = 10000,
    consume = function(batch)
      Block.batch_store_bootstrap(batch)
    end
  }
  
  local function bulk_pull_worker(acct_frontier)
    local peer = assert(Peer.get_best_bootstrap_peer())
    active_peers[peer] = {frontier = acct_frontier, blocks_pulled = 0}
    local prev_blocks, slow_in_a_row = 0, 0
    local acct_blocks_count, frontier_hash_found_or_err = Account.bulk_pull(acct_frontier, peer, {
      consume = function(batch)
        --blocks should have already been PoW and sig checked
        for _, block in ipairs(batch) do
          sink:add(block)
        end
        return #batch
      end,
      watchdog = function(blocks_so_far_count)
        --print(tostring(peer), blocks_so_far_count, prev_blocks)
        local blocks_fetched = blocks_so_far_count - prev_blocks
        prev_blocks = blocks_so_far_count
        if blocks_fetched < min_speed then -- too slow
          if slow_in_a_row > 2 then
            return false, "account pull too slow"
          else
            slow_in_a_row = slow_in_a_row + 1
          end
        else
          active_peers[peer].blocks_pulled = blocks_so_far_count
        end
      end
    })
    
    --print("bulk   pull... done")
    active_peers[peer]=nil
    
    if acct_blocks_count then
      if frontier_hash_found_or_err then
        --everything's okay
        total_blocks_fetched = total_blocks_fetched + acct_blocks_count
        peer:update_bootstrap_score(account_frontier_score_delta)
        return acct_blocks_count
      else
        --assume it's the peer's fault we didn't find the frontier hash
        -- ATTACK VECTOR: this assumes we trust the frontier, which means an attacker
        -- that poisons the frontier will eventually gain bootstrap-score over legit peers
        total_blocks_fetched = total_blocks_fetched + acct_blocks_count
        peer:update_bootstrap_score(-100 * account_frontier_score_delta)
        print("peer", tostring(peer), "account found, but without frontier. that's okay though, we'll take it")
        --return nil, "account found, but without frontier"
        return acct_blocks_count
      end
    else -- there was an error
      local err = frontier_hash_found_or_err
      log:debug("bootstrap:  acct pull %s from peer %s error %s", Account.to_readable(acct_frontier.account), tostring(peer), err)
      if err:match("^bad signature") or err:match("^bad PoW") or err:match("^bad block") then
        peer:update_bootstrap_score(- 100 * account_frontier_score_delta)
      elseif err == "account pull too slow" then
        peer:update_bootstrap_score(- 10 * account_frontier_score_delta)
      elseif err == "Connection refused" or err == "No route to host" then
        peer:update_bootstrap_score(-1)
      else
        peer:update_bootstrap_score(-account_frontier_score_delta)
      end
      return nil, err
    end
  end
  
  local current_frontier_size = frontier_size
  
  local function bulk_pull_progress(active_workers, work_done, _, work_failed)
    local bus_data = {
      complete = false,
      active_peers = active_peers,
      frontier_size = frontier_size,
      accounts_fetched = #work_done,
      accounts_failed = #work_failed
    }
    log:debug("bulk pull: using %i workers, finished %i of %i accounts [%3.2f%%] (%i blocks) (%i failed attempts)", active_workers, #work_done, current_frontier_size, 100 * #work_done / current_frontier_size, total_blocks_fetched, #work_failed)
    
    Bus.pub("bulk_pull:progress", bus_data)
  end
  local ok, failed, errs
  for i=1, 5 do
    ok, failed, errs = coroutine.workpool({
      work = function()
        return source:next()
      end,
      max_workers = config.bootstrap.max_peers,
      retry = 2,
      progress = bulk_pull_progress,
      worker = bulk_pull_worker
    })
    sink:finish()
    total_accounts_fetched = total_accounts_fetched + #ok
    log:debug("bulk_pull attempt %i: %i pulled, %i failed", i, #ok, #failed)
    
    if #failed == 0 then
      break
    else
      --retry what's failed
      current_frontier_size = #failed
      source = Util.BatchSource(function(n)
        if n == 0 then
          return failed
        else
          return nil
        end
      end)
    end
  end
  
  local bus_data = {
    complete = true,
    frontier_size = frontier_size,
    accounts_fetched = total_accounts_fetched,
    accounts_failed = total_accounts_failed,
    blocks_fetched = total_blocks_fetched
  }
  
  Bus.pub("bulk_pull:progress",  bus_data)
  return total_accounts_fetched, failed, errs
end

function Nanonet.fetch_frontiers(min_good_frontier_requests)
  local min_frontiers_per_sec = 200
  min_good_frontier_requests = min_good_frontier_requests or 3
  
  local good_frontier_requests = 0
  local active_peers = {}
  local largest_frontier_pull_size = tonumber(DB.kv.get("largest_frontier_pull") or 0)
  if config.bootstrap.min_frontier_size > largest_frontier_pull_size then
    largest_frontier_pull_size = config.bootstrap.min_frontier_size
  end
  
  local function check_completion()
    if good_frontier_requests < min_good_frontier_requests then
      return false
    else
      --the work is done. stop all active peers
      local peers_to_stop = {}
      for peer, _ in pairs(active_peers) do
        if peer.tcp then
          table.insert(peers_to_stop, peer)
        end
      end
      for _, peer in ipairs(peers_to_stop) do
        peer.tcp:stop("frontier fetch finished")
      end
      return true
    end
  end
  
  local frontiers_set, failed, errs = coroutine.workpool({
    work = function()
      if check_completion() then
        return nil
      else
        return assert(Peer.get_best_bootstrap_peer())
      end
    end,
    retry = 0,
    progress = (function()
      local last_failed_peer = 1
      return function(active_workers, work_done, _, peers_failed, peers_failed_err)
        local bus_data = {
          complete = false,
          frontier_requests_completed = #work_done,
          active_peers = active_peers,
          failed_peers = {}
        }
        good_frontier_requests = #work_done
        if not check_completion() then
          log:debug("frontiers: downloading from %i peers. (%i/%i complete) (%i failed)", active_workers, #work_done, min_good_frontier_requests, #peers_failed)
          for peer, stats in pairs(active_peers) do
            log:debug("frontiers: %5d/sec frontiers (%7d total) [%5.2f%%] from %s", stats.rate or 0, (stats.total or 0), (stats.progress or 0) * 100, peer)
          end
          while last_failed_peer <= #peers_failed do
            local failed_peer = peers_failed[last_failed_peer]
            local failed_peer_error = peers_failed_err[last_failed_peer]
            log:debug("frontiers:   pull failed from %s: %s", failed_peer, failed_peer_error)
            last_failed_peer = last_failed_peer + 1
            bus_data.failed_peers[failed_peer] = failed_peer_error
          end
          Bus.pub("fetch_frontiers:progress", bus_data)
        else
          log:debug("frontiers: pull complete")
        end
      end
    end)(),
    worker = function(peer)
      local frontier_pull_size_estimated = false
      local times_below_min_rate = 0
      local prev_frontiers_count = 0
      --log:debug("bootstrap: starting frontier pull from %s", peer)
      
      active_peers[peer] = {}
      local frontiers, err = Frontier.fetch(peer, function(frontiers_so_far_count, progress)
        --watchdog checker for frontier fetch progress
        
        local frontiers_per_sec = frontiers_so_far_count - prev_frontiers_count
        prev_frontiers_count = frontiers_so_far_count
        if frontiers_per_sec < min_frontiers_per_sec then
          --too slow
          times_below_min_rate = times_below_min_rate + 1
          if times_below_min_rate > 4 then
            return false, ("too slow (%i frontiers/sec)"):format(frontiers_per_sec)
          end
        elseif progress > 0.2 and not frontier_pull_size_estimated then
          --is this pull going to be too small (i.e. from an unsynced node)?
          frontier_pull_size_estimated = true
          if frontiers_so_far_count * 1/progress < 0.8 * largest_frontier_pull_size then
            --too small
            return false, ("frontier is too small (circa %.0f, expected %.0f)"):format(frontiers_so_far_count * 1/progress, largest_frontier_pull_size)
          end
        end
        --track statistics
        active_peers[peer].rate = frontiers_per_sec
        active_peers[peer].total = frontiers_so_far_count
        active_peers[peer].progress = progress
        return true
      end)
      active_peers[peer]=nil
      return frontiers, err
    end,
    check = function(peer, res)
      if not res then
        peer:update_bootstrap_score(-1)
      end
    end
  })
  Bus.pub("fetch_frontiers:progress", {
    complete = true,
    frontier_requests_completed = #frontiers_set
  })
  
  return frontiers_set, failed, errs
end

function Nanonet.bulk_pull_blocks(opt, peer)
  local msg = Message.new("bulk_pull_blocks", opt)
  
  if not peer then
    -- try this with a few compatible peers
    local res, err
    for i, try_peer in ipairs(Peer.get_best_bootstrap_peer{min_version=6, limit=20}) do
      print("try", i, tostring(try_peer))
      res, err = Nanonet.bulk_pull_blocks(opt, try_peer)
      if res and #res > 0 then
        return res
      end
    end
    return res, err
  end
  
  assert(peer)
  
  local min_hash, max_hash, max_count = msg.min_hash, msg.max_hash, msg.max_count
  local function check_block(block)
    if block.hash < min_hash or block.hash > max_hash then
      return nil, "block out of range"
    end
    if not block:verify_PoW() then
      return nil, "PoW check failed"
    end
    return true
  end
  
  if not peer then return nil, "couldn't find appropriate peer" end
  local block
  local blocks = {}
  local res, tcp_err = peer:tcp_session("bulk pull blocks", function(tcp)
    tcp:write(msg:pack())
    while tcp:read() do
      local buf = tcp.buf:flush()
      print(Util.bytes_to_hex_debug(buf))
      if msg.mode == "list" then
        local fresh_blocks, leftovers_or_err, done = Parser.unpack_bulk(buf)
        
        if fresh_blocks then
          for _, blockdata in ipairs(fresh_blocks) do
            block = Block.new(blockdata)
            local ok, err = check_block(block)
            if not ok then
              return nil, err
            else
              table.insert(blocks, block)
              if #blocks > max_count then
                return nil, "too many blocks sent"
              end
            end
          end
          
          if leftovers_or_err and #leftovers_or_err > 0 then
            tcp.buf:push(leftovers_or_err)
          end
        end
        
        if done then
          return blocks
        end
        
      else --checksum
        return buf --just the checksum, right?
      end
    end
  end)
  
  return res, tcp_err
end

return Nanonet
