#!/usr/bin/ruby
# frozen_string_literal: true

require 'json'
require 'yaml'
require 'time'
require 'ipaddr'
require 'digest'
require 'fileutils'
require 'socket'
require 'uri'
require 'timeout'
require 'tmpdir'
require 'securerandom'
require 'net/http'
require 'optparse'

module ProxySentry
  # Independent, opt-in repair helper. It never changes system proxy state.
  class Watchdog
    # Separate from StandardError so nested request/probe rescues cannot swallow the attempt deadline.
    class AttemptExpired < Exception; end
    class ConfigScalarScanner < Psych::ScalarScanner
      def tokenize(value)
        # Mihomo emits unquoted listener strings such as :9097; these are not Ruby Symbols.
        value.start_with?(':') ? value : super
      end
    end
    MAX_BYTES = 1_048_576
    THROTTLE = 180
    def initialize(home:, core: nil, socket_path: nil, parent_pid: nil, clock: -> { Time.now }, io: nil)
      @home, @core, @socket_path, @parent_pid, @clock, @io = File.expand_path(home), core, socket_path, parent_pid, clock, io
      @root = File.join(@home, 'Library', 'Application Support', 'ProxySentry')
      @settings_path = File.join(@root, 'watchdog-settings.json')
      @signal_path = File.join(@root, 'agent-status.json')
      @status_path = File.join(@root, 'watchdog-status.json')
      @lock_path = File.join(@root, 'watchdog.lock')
      @journal_path = File.join(@root, 'watchdog-journal.json')
      @cancelled = false
    end

    def run(once: false, check: false)
      %w[TERM INT].each { |signal| trap(signal) { @cancelled = true } }
      prepare_root
      return publish('legacy_conflict') if legacy_conflict?
      if check
        return publish('manual_recovery') if File.exist?(@journal_path)
        ctx = prerequisites? && context
        return publish('unsupported') unless ctx
        settings = read_json(@settings_path) || {}
        domain = [ctx['selection']['server'], ctx['profile_node']['server'], settings['entryDomain']].any? { |s| fqdn?(s) }
        return publish(domain ? 'ready' : 'needs_domain')
      end
      settings = read_json(@settings_path)
      unless settings && settings['enabled'] == true
        return publish('disabled')
      end
      return publish('unsupported') unless prerequisites?
      unless once || check
        return publish('waiting')
      end
      return publish('cancelled') if @cancelled || !parent_alive?
      with_lock do
        if File.exist?(@journal_path)
          next publish(rollback(read_json(@journal_path)) ? 'rolled_back' : 'manual_recovery')
        end
        signal = read_json(@signal_path)
        next publish('waiting') unless fresh_red_signal?(signal)
        next publish('cooldown') if throttled?(signal)
        begin
          Timeout.timeout(90, AttemptExpired) { attempt(settings, signal) }
        rescue StandardError, AttemptExpired
          if File.exist?(@journal_path)
            publish(rollback(read_json(@journal_path)) ? 'rolled_back' : 'manual_recovery')
          else
            publish(@cancelled ? 'cancelled' : 'unavailable')
          end
        end
      end
    rescue Errno::EACCES, Errno::ENOENT
      publish('unavailable')
    rescue StandardError
      publish('unavailable')
    end

    def self.safe_yaml(text)
      document = Psych.parse(text)
      return {} unless document
      reject_duplicate_mappings!(document.root)
      loader = Psych::ClassLoader::Restricted.new([], [])
      Psych::Visitors::NoAliasRuby.new(ConfigScalarScanner.new(loader), loader).accept(document) || {}
    rescue Psych::Exception, NoMethodError, ArgumentError
      nil
    end

    private

    def attempt(settings, signal)
      publish('checking')
      return publish('cancelled') if @cancelled || !parent_alive?
      mark_attempt(signal)
      ctx = context
      return publish('unsupported') unless ctx
      selection = ctx['selection']
      domain = [selection['server'], ctx['profile_node']['server'], settings['entryDomain']].find { |s| fqdn?(s) }
      return publish('needs_domain') unless fqdn?(domain)
      candidates = resolve(domain)
      return publish('no_candidate') if candidates.empty?
      candidate = candidates.find { |ip| probe_candidate(selection, ip) }
      return publish('no_candidate') unless candidate
      return publish('cancelled') if @cancelled || !parent_alive?
      return publish('config_changed') unless unchanged?(ctx, settings, signal)
      publish(transaction(ctx, settings, signal, candidate))
    end

    def prerequisites?
      return false unless @core && File.file?(@core) && File.executable?(@core)
      return false unless @socket_path && File.socket?(@socket_path)
      !legacy_conflict?
    end

    def config_paths
      index_path = File.join(clash_root, 'profiles.yaml')
      return nil unless regular_private?(index_path)
      index = self.class.safe_yaml(File.binread(index_path))
      return nil unless index.is_a?(Hash) && index['items'].is_a?(Array)
      items = index['items'].select { |item| item.is_a?(Hash) && item['uid'] == index['current'] }
      return nil unless items.length == 1 && %w[remote local].include?(items[0]['type'])
      file = items[0]['file']
      return nil unless file.is_a?(String) && file.match?(/\A[A-Za-z0-9_-]+\.ya?ml\z/)
      paths = [File.join(clash_root, 'clash-verge.yaml'), File.join(clash_root, 'profiles', file)]
      paths.all? { |p| regular_private?(p) } ? paths : nil
    end

    def selection_from_socket(runtime)
      configs = socket_json('GET', '/configs')
      proxies = socket_json('GET', '/proxies')
      mode = configs && (configs['mode'] || configs.dig('configs', 'mode'))
      global = proxies && (proxies['proxies'] || proxies)['GLOBAL']
      leaf = global && global['now']
      node = proxies && (proxies['proxies'] || proxies)[leaf]
      return nil unless mode.to_s.downcase == 'global' && leaf && node && node['type'].to_s.downcase == 'vless'
      matches = Array(runtime['proxies']).select { |p| p.is_a?(Hash) && p['name'] == leaf }
      return nil unless matches.length == 1
      { 'server' => matches[0]['server'], 'runtimeNode' => leaf, 'profileNode' => leaf, 'node' => matches[0],
        'mixed_port' => configs['mixed-port'] }
    end

    def context
      paths = config_paths
      return nil unless paths
      bytes = paths.map { |p| File.binread(p) }
      runtime, profile = bytes.map { |b| self.class.safe_yaml(b) }
      return nil unless runtime.is_a?(Hash) && profile.is_a?(Hash)
      # A tunneled base probe cannot independently establish Internet health.
      return nil if runtime.dig('tun', 'enable') == true || runtime['dialer-proxy']
      selection = selection_from_socket(runtime)
      return nil unless selection
      node = selection['node']
      return nil unless node['type'].to_s.downcase == 'vless' && [nil, 'tcp'].include?(node['network']) &&
                        node['reality-opts'].is_a?(Hash) && node['tls'] == true && !node['dialer-proxy']
      matches = Array(profile['proxies']).select { |p| p.is_a?(Hash) && p['name'] == selection['profileNode'] }
      return nil unless matches.length == 1
      # Never guess which subscription credential corresponds to the active runtime node.
      keys = %w[type port uuid flow tls servername reality-opts client-fingerprint network]
      return nil unless keys.all? { |k| node[k] == matches[0][k] }
      port = selection['mixed_port']
      return nil unless port.is_a?(Integer) && (1..65535).cover?(port)
      { 'paths' => paths, 'bytes' => bytes, 'selection' => selection, 'profile_node' => matches[0],
        'index_hash' => sha(File.binread(File.join(clash_root, 'profiles.yaml'))) }
    rescue StandardError
      nil
    end

    def unchanged?(ctx, settings, signal)
      return false if @cancelled || !parent_alive? || legacy_conflict?
      return false unless read_json(@settings_path) == settings && settings['enabled'] == true
      current_signal = read_json(@signal_path)
      return false unless fresh_red_signal?(current_signal) && current_signal['checkedAt'] == signal['checkedAt']
      current = context
      current && current == ctx
    end

    def transaction(ctx, settings, signal, address)
      edited = ctx['bytes'].map { |b| replace_selected_server(b, ctx['selection']['runtimeNode'], address) }
      return 'unsupported' if edited.any?(&:nil?)
      return 'no_candidate' if edited == ctx['bytes']
      return 'unsupported' unless validate_config(edited[0])
      return 'config_changed' unless unchanged?(ctx, settings, signal)
      backup_root = File.join(@root, 'watchdog-backups')
      private_directory(backup_root)
      backup = Dir.mktmpdir('repair-', backup_root)
      records = ctx['paths'].each_with_index.map do |path, i|
        original_path = File.join(backup, "#{i}.yaml")
        atomic_write(original_path, ctx['bytes'][i], 0600)
        { 'path' => path, 'backup' => original_path, 'before' => sha(ctx['bytes'][i]), 'after' => sha(edited[i]) }
      end
      journal = { 'schemaVersion' => 1, 'files' => records, 'reload' => false, 'index_hash' => ctx['index_hash'] }
      atomic_write(@journal_path, JSON.generate(journal), 0600)
      publish('repairing')
      records.each_with_index do |record, i|
        raise 'cancelled' if @cancelled || !parent_alive? || read_json(@settings_path) != settings || legacy_conflict?
        raise 'changed' unless records.each_with_index.all? { |r, j| regular_private?(r['path']) && sha(File.binread(r['path'])) == r[j < i ? 'after' : 'before'] }
        raise 'changed' unless sha(File.binread(File.join(clash_root, 'profiles.yaml'))) == ctx['index_hash']
        raise 'changed' unless config_paths == ctx['paths'] && selection_from_socket(self.class.safe_yaml(ctx['bytes'][0])) == ctx['selection']
        raise 'changed' unless fresh_red_signal?(read_json(@signal_path))
        atomic_write(record['path'], edited[i], 0600)
      end
      raise 'changed' unless records.all? { |r| regular_private?(r['path']) && sha(File.binread(r['path'])) == r['after'] }
      raise 'cancelled' if @cancelled || !parent_alive? || read_json(@settings_path) != settings
      journal['reload'] = true
      atomic_write(@journal_path, JSON.generate(journal), 0600)
      raise 'reload' unless reload_config(ctx['paths'][0])
      raise 'verify' unless reload_and_verify?(ctx['selection'])
      raise 'cancelled' if @cancelled || !parent_alive? || read_json(@settings_path) != settings
      raise 'changed' unless records.all? { |r| regular_private?(r['path']) && sha(File.binread(r['path'])) == r['after'] }
      File.delete(@journal_path)
      'repaired'
    rescue StandardError
      return 'unavailable' unless journal
      rollback(journal) ? 'rolled_back' : 'manual_recovery'
    end

    def validate_config(bytes)
      Dir.mktmpdir('proxysentry-validate-') do |dir|
        path = File.join(dir, 'config.yaml')
        atomic_write(path, bytes, 0600)
        pid = Process.spawn(clean_environment, @core, '-t', '-d', dir, '-f', path,
                            unsetenv_others: true, out: File::NULL, err: File::NULL)
        begin
          Timeout.timeout(5) { Process.wait(pid); return $?.success? }
        ensure
          reap(pid)
        end
      end
    end

    def reload_config(path)
      response = socket_request('PUT', '/configs', JSON.generate('path' => path))
      response && (200..299).cover?(response[0])
    end

    def resolve(domain)
      pools = %w[223.5.5.5 1.12.12.12].map { |resolver| resolve_direct(domain, resolver) }
      pools += %w[https://dns.google/resolve?name= https://cloudflare-dns.com/dns-query?name=].map do |base|
        uri = URI.parse(base + URI.encode_www_form_component(domain))
        req = Net::HTTP::Get.new(uri); req['accept'] = 'application/dns-json'
        http = Net::HTTP.new(uri.host, 443, nil); http.use_ssl = true; http.open_timeout = 4; http.read_timeout = 4
        json = Timeout.timeout(6) { http.request(req).body }
        next [] if json.bytesize > MAX_BYTES
        Array(JSON.parse(json)['Answer']).select { |a| a['type'].to_i == 1 && public_ip?(a['data']) }.map { |a| a['data'] }
      rescue StandardError
        []
      end
      # Bounded round-robin keeps one resolver's larger answer from hiding all other pools.
      (0...(pools.map(&:length).max || 0)).flat_map { |i| pools.map { |pool| pool[i] } }.compact.uniq.take(8)
    rescue StandardError
      []
    end

    def resolve_direct(domain, resolver)
      return [] unless fqdn?(domain) && File.executable?('/usr/bin/dig')
      reader, writer = IO.pipe
      pid = Process.spawn(clean_environment, '/usr/bin/dig', "@#{resolver}", '+short', '+time=2', '+tries=1',
                          domain, 'A', unsetenv_others: true, out: writer, err: File::NULL)
      writer.close
      Timeout.timeout(3) do
        bytes = reader.read(65_536)
        Process.wait(pid)
        bytes.lines.map(&:strip).select { |ip| public_ip?(ip) }.uniq
      end
    rescue StandardError
      []
    ensure
      reader.close if reader && !reader.closed?
      writer.close if writer && !writer.closed?
      reap(pid) if pid
    end

    def probe_candidate(selection, ip)
      return false unless @core && public_ip?(ip) && selection.is_a?(Hash) && selection['node'].is_a?(Hash)
      node = deep_copy(selection['node']); node['name'] = 'candidate'; node['server'] = ip
      Dir.mktmpdir('psw-', '/tmp') do |dir|
        listener = TCPServer.new('127.0.0.1', 0)
        port = listener.addr[1]; listener.close
        socket_path = File.join(dir, 'c.sock'); config = File.join(dir, 'c.yaml')
        atomic_write(config, YAML.dump('mode' => 'rule', 'tun' => { 'enable' => false }, 'dns' => { 'enable' => false },
          'mixed-port' => port, 'bind-address' => '127.0.0.1', 'allow-lan' => false,
          'external-controller' => '', 'external-controller-unix' => socket_path,
          'secret' => '', 'log-level' => 'silent', 'proxies' => [node], 'rules' => ['MATCH,candidate']), 0600)
        env = { 'PATH' => '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME' => dir, 'LANG' => 'C' }
        pid = Process.spawn(env, @core, '-d', dir, '-f', config, unsetenv_others: true, out: '/dev/null', err: '/dev/null')
        begin
          Timeout.timeout(15) do
            return false unless probe_wait_socket(socket_path, pid, 3)
            2.times.all? do
              !@cancelled && parent_alive? && probe_delay(socket_path, 'https://www.google.com/generate_204') &&
                real_traffic?(port)
            end
          end
        ensure
          probe_stop(pid)
        end
      end
    rescue StandardError
      false
    end

    def probe_wait_socket(path, pid, seconds)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      until File.socket?(path)
        return false if Process.waitpid(pid, Process::WNOHANG)
        return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.05
      end
      true
    end

    def probe_delay(path, target)
      body = probe_http(path, "/proxies/candidate/delay?timeout=3000&url=#{URI.encode_www_form_component(target)}")
      value = JSON.parse(body)['delay']
      value.is_a?(Numeric) && value > 0
    rescue StandardError
      false
    end

    def probe_http(path, request_path)
      Timeout.timeout(4) do
        socket = UNIXSocket.new(path)
        socket.write("GET #{request_path} HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        raw = socket.read(65_536)
        raise 'http' unless raw.start_with?('HTTP/1.0 200 ', 'HTTP/1.1 200 ')
        raw.split("\r\n\r\n", 2).fetch(1)
      ensure
        socket.close if socket && !socket.closed?
      end
    end

    def probe_stop(pid)
      reap(pid)
    end

    def deep_copy(value)
      value.is_a?(Hash) ? value.each_with_object({}) { |(k, v), h| h[k] = deep_copy(v) } : (value.is_a?(Array) ? value.map { |v| deep_copy(v) } : value)
    end

    def reload_and_verify?(selection)
      2.times.all? do
        configs = socket_json('GET', '/configs')
        proxies = socket_json('GET', '/proxies')
        next false if @cancelled || !parent_alive?
        next false unless configs && configs['mode'].to_s.downcase == 'global' && configs['mixed-port'] == selection['mixed_port'] &&
                          proxies && proxies.dig('proxies', 'GLOBAL', 'now') == selection['runtimeNode']
        path = '/proxies/' + URI.encode_www_form_component(selection['runtimeNode']).gsub('+', '%20') +
          '/delay?timeout=3000&url=' + URI.encode_www_form_component('https://www.google.com/generate_204')
        delay = socket_json('GET', path)
        delay && delay['delay'].is_a?(Numeric) && delay['delay'] > 0 && real_traffic?(selection['mixed_port'])
      end
    end

    def real_traffic?(port)
      %w[https://www.google.com/generate_204 https://cp.cloudflare.com/generate_204].all? do |target|
        uri = URI(target)
        http = Net::HTTP::Proxy('127.0.0.1', port).new(uri.host, uri.port)
        http.use_ssl = true; http.open_timeout = 3; http.read_timeout = 3
        Timeout.timeout(4) do
          response = http.get(uri.request_uri)
          %w[200 204].include?(response.code) && response.body.to_s.bytesize < 4096
        end
      end
    rescue StandardError
      false
    end

    def replace_selected_server(text, node_name, address)
      return nil unless public_ip?(address) && self.class.safe_yaml(text).is_a?(Hash)
      root = Psych.parse(text).root
      pair = root.children.each_slice(2).find { |key, _| key.value == 'proxies' }
      return nil unless pair && pair[1].is_a?(Psych::Nodes::Sequence)
      nodes = pair[1].children.select do |node|
        node.is_a?(Psych::Nodes::Mapping) && node.children.each_slice(2).any? { |k, v| k.value == 'name' && v.is_a?(Psych::Nodes::Scalar) && v.value == node_name }
      end
      return nil unless nodes.length == 1
      server = nodes[0].children.each_slice(2).find { |k, _| k.value == 'server' }
      return nil unless server && server[1].is_a?(Psych::Nodes::Scalar)
      scalar = server[1]
      return nil unless scalar.start_line == scalar.end_line && !scalar.anchor
      # Psych columns count characters, not UTF-8 bytes; preserve comments/flow style/other nodes.
      utf8 = text.dup.force_encoding(Encoding::UTF_8)
      return nil unless utf8.valid_encoding?
      lines = utf8.lines
      line = lines[scalar.start_line]
      lines[scalar.start_line] = line[0...scalar.start_column] + address + line[scalar.end_column..-1]
      result = lines.join
      expected = self.class.safe_yaml(utf8)
      expected['proxies'].find { |p| p['name'] == node_name }['server'] = address
      self.class.safe_yaml(result) == expected ? result : nil
    rescue StandardError
      nil
    end

    def rollback(journal)
      return false unless valid_journal?(journal)
      records = journal['files']
      return false unless config_paths == records.map { |r| r['path'] } &&
        sha(File.binread(File.join(clash_root, 'profiles.yaml'))) == journal['index_hash']
      # Preflight BOTH files before restoring either. An outside edit stops all rollback writes.
      return false unless records.all? do |r|
        regular_private?(r['path']) && regular_private?(r['backup']) && sha(File.binread(r['backup'])) == r['before'] &&
          [r['before'], r['after']].include?(sha(File.binread(r['path'])))
      end
      records.each do |r|
        current = sha(File.binread(r['path']))
        next if current == r['before']
        return false unless current == r['after']
        atomic_write(r['path'], File.binread(r['backup']), 0600)
      end
      return false if journal['reload'] && !reload_config(records[0]['path'])
      File.delete(@journal_path) if File.exist?(@journal_path)
      true
    rescue StandardError
      # Leave the journal for manual recovery; never clobber an outside edit.
    end

    def with_lock
      raise 'unsafe lock' if File.symlink?(@lock_path)
      File.open(@lock_path, File::RDWR | File::CREAT, 0600) do |f|
        return publish('waiting') unless f.flock(File::LOCK_EX | File::LOCK_NB)
        yield
      end
    end

    def fresh_red_signal?(s)
      return false unless s.is_a?(Hash) && s['schemaVersion'] == 1 && s.dig('diagnosis', 'state') == 'red'
      exp = Time.iso8601(s['expiresAt'].to_s); checked = Time.iso8601(s['checkedAt'].to_s)
      return false if exp <= @clock.call || checked > @clock.call || @clock.call - checked >= 120 || exp - checked > 120
      ev = Array(s['evidence']); direct = ev.any? { |e| e['category'] == 'direct' && e['outcome'] == 'success' }
      port = ev.any? { |e| e['category'] == 'localPort' && e['outcome'] == 'success' }
      real = ev.select { |e| e['category'] == 'proxy' && %w[failure timeout].include?(e['outcome']) }
      core = %w[clashVersion clashConfigs].all? { |category| ev.any? { |e| e['category'] == category && e['outcome'] == 'success' } } &&
        ev.any? { |e| e['category'] == 'node' && %w[success failure timeout].include?(e['outcome']) }
      direct && port && core && real.length >= 2 && ev.none? { |e| e['category'] == 'proxy' && e['outcome'] == 'success' }
    rescue ArgumentError, TypeError, NoMethodError
      false
    end

    def throttled?(s)
      last = read_json(File.join(@root, 'watchdog-attempt.json'))
      last && (last['signal'] == s['checkedAt'] || @clock.call - Time.iso8601(last['at']) < THROTTLE)
    end
    def mark_attempt(s); atomic_write(File.join(@root, 'watchdog-attempt.json'), JSON.generate('signal' => s['checkedAt'], 'at' => @clock.call.utc.iso8601), 0600); end
    def publish(code); out = result(code); atomic_write(@status_path, JSON.generate(out), 0600); @io.write(JSON.generate(out) + "\n") if @io; out; end
    def result(code); { 'schemaVersion' => 1, 'state' => code, 'checkedAt' => @clock.call.utc.iso8601(6), 'expiresAt' => (@clock.call + 300).utc.iso8601(6) }; end
    def read_json(path); regular_private?(path) ? JSON.parse(File.binread(path)) : nil; rescue JSON::ParserError; nil; end
    def regular_private?(path); st = File.lstat(path); st.file? && !st.symlink? && st.uid == Process.uid && st.size <= MAX_BYTES; rescue SystemCallError; false; end
    def parent_alive?; @parent_pid.nil? || (@parent_pid.to_i > 0 && Process.kill(0, @parent_pid.to_i)); rescue Errno::ESRCH; false; rescue Errno::EPERM; true; end
    def legacy_conflict?
      launch_agents = File.join(@home, 'Library', 'LaunchAgents')
      File.exist?(File.join(launch_agents, 'com.justinjia.clash-watchdog.plist')) || File.exist?('/tmp/clash-watchdog.lock')
    end
    def fqdn?(s); s.to_s =~ /\A(?=.{1,253}\z)(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}\z/; end
    def public_ip?(s)
      return false unless s.is_a?(String) && s.match?(/\A\d{1,3}(?:\.\d{1,3}){3}\z/)
      ip = IPAddr.new(s)
      ip.ipv4? && %w[0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.168.0.0/16 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/3].none? { |range| IPAddr.new(range).include?(ip) }
    rescue IPAddr::InvalidAddressError
      false
    end
    def sha(v); Digest::SHA256.hexdigest(v); end
    def atomic_write(path, bytes, mode)
      raise 'symlink' if File.symlink?(path)
      tmp = "#{path}.tmp-#{SecureRandom.hex(8)}"
      File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, mode) { |f| f.write(bytes); f.flush; f.fsync }
      File.rename(tmp, path)
      File.open(File.dirname(path)) { |dir| dir.fsync }
    ensure
      File.delete(tmp) if tmp && File.exist?(tmp)
    end
    def socket_json(method, path)
      response = socket_request(method, path)
      response && response[0] == 200 ? JSON.parse(response[1]) : nil
    rescue StandardError
      nil
    end

    def socket_request(method, path, body = '')
      Timeout.timeout(4) do
        s = UNIXSocket.new(@socket_path)
        s.write("#{method} #{path} HTTP/1.0\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
        raw = s.read(MAX_BYTES + 1)
        return nil if raw.bytesize > MAX_BYTES
        header, data = raw.split("\r\n\r\n", 2)
        [header.split(' ')[1].to_i, data]
      ensure
        s.close if s && !s.closed?
      end
    rescue StandardError
      nil
    end

    def clash_root; File.join(@home, 'Library/Application Support/io.github.clash-verge-rev.clash-verge-rev'); end
    def clean_environment; { 'PATH' => '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME' => @home, 'LANG' => 'en_US.UTF-8' }; end
    def prepare_root; private_directory(@root); end
    def private_directory(path)
      raise 'symlink' if File.symlink?(path)
      FileUtils.mkdir_p(path, mode: 0700)
      raise 'owner' unless File.stat(path).uid == Process.uid
      File.chmod(0700, path)
    end
    def reap(pid)
      return if Process.waitpid(pid, Process::WNOHANG)
      Process.kill('TERM', pid)
      Timeout.timeout(1) { Process.wait(pid) }
    rescue Timeout::Error
      Process.kill('KILL', pid) rescue nil
      Process.wait(pid) rescue nil
    rescue Errno::ECHILD, Errno::ESRCH
      nil
    end
    def valid_journal?(journal)
      return false unless journal.is_a?(Hash) && journal['schemaVersion'] == 1 && journal['files'].is_a?(Array) && journal['files'].length == 2
      records = journal['files']
      return false unless records[0]['path'] == File.join(clash_root, 'clash-verge.yaml') &&
        records[1]['path'].to_s.match?(/\A#{Regexp.escape(File.join(clash_root, 'profiles'))}\/[A-Za-z0-9_-]+\.ya?ml\z/)
      records.all? do |r|
        r['backup'].to_s.match?(/\A#{Regexp.escape(File.join(@root, 'watchdog-backups'))}\/repair-[^\/]+\/[01]\.yaml\z/) &&
          %w[before after].all? { |key| r[key].to_s.match?(/\A[0-9a-f]{64}\z/) }
      end
    end
    def self.reject_duplicate_mappings!(node)
      return unless node
      if node.is_a?(Psych::Nodes::Mapping)
        keys = node.children.each_slice(2).map { |k, _| k.is_a?(Psych::Nodes::Scalar) ? k.value : nil }
        raise Psych::Exception, 'unsupported mapping' if keys.include?(nil) || keys.include?('<<') || keys.uniq.length != keys.length
      end
      Array(node.children).each { |c| reject_duplicate_mappings!(c) }
    end
  end
end

if $PROGRAM_NAME == __FILE__
  args = {}
  OptionParser.new do |parser|
    %w[home core socket parent-pid].each { |key| parser.on("--#{key} VALUE") { |v| args[key] = v } }
    parser.on('--once') { args['once'] = true }
    parser.on('--check') { args['check'] = true }
  end.parse!
  ProxySentry::Watchdog.new(home: args.fetch('home'), core: args['core'], socket_path: args['socket'], parent_pid: args['parent-pid']).run(once: args['once'], check: args['check'])
end
