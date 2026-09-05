require 'minitest/autorun'
require 'tmpdir'
require_relative '../ProxySentry/watchdog'

class WatchdogTest < Minitest::Test
  class FakeWatchdog < ProxySentry::Watchdog
    attr_accessor :verify, :outside_edit, :abort_change, :cancel_after_write
    def prerequisites?; true; end
    def legacy_conflict?; false; end
    def socket_json(_method, path)
      node = { 'name' => 'node', 'type' => 'vless', 'network' => 'tcp', 'server' => 'entry.example.com', 'port' => 443,
               'uuid' => 'synthetic', 'flow' => '', 'tls' => true, 'servername' => 'entry.example.com',
               'reality-opts' => { 'public-key' => 'synthetic' }, 'client-fingerprint' => 'chrome' }
      return { 'mode' => 'global', 'mixed-port' => 7890 } if path == '/configs'
      { 'proxies' => { 'GLOBAL' => { 'now' => 'node' }, 'node' => node } }
    end
    def resolve(_domain); ['8.8.8.8']; end
    def probe_candidate(_selection, _ip); true; end
    def validate_config(_bytes); true; end
    def reload_config(_path)
      File.write(@outside_edit, "external\n") if @outside_edit
      @cancelled = true if @cancel_after_write
      true
    end
    def reload_and_verify?(_selection); !!@verify; end
    def unchanged?(ctx, settings, signal); return false if @abort_change; super; end
  end

  def setup
    @home = Dir.mktmpdir('proxysentry-watchdog-')
    @root = File.join(@home, 'Library', 'Application Support', 'ProxySentry')
    FileUtils.mkdir_p(@root, mode: 0700)
    @now = Time.utc(2026, 9, 5, 1)
    @wd = ProxySentry::Watchdog.new(home: @home, clock: -> { @now })
    @wd.define_singleton_method(:legacy_conflict?) { false }
  end
  def teardown; FileUtils.remove_entry(@home); end

  def fixture
    root = File.join(@home, 'Library/Application Support/io.github.clash-verge-rev.clash-verge-rev')
    profiles = File.join(root, 'profiles'); FileUtils.mkdir_p(profiles, mode: 0700)
    node = { 'name' => 'node', 'type' => 'vless', 'network' => 'tcp', 'server' => 'entry.example.com', 'port' => 443,
             'uuid' => 'synthetic', 'flow' => '', 'tls' => true, 'servername' => 'entry.example.com',
             'reality-opts' => { 'public-key' => 'synthetic' }, 'client-fingerprint' => 'chrome' }
    runtime = { 'tun' => { 'enable' => false }, 'mixed-port' => 7890, 'proxies' => [node] }
    base = File.join(@home, 'Library/Application Support/ProxySentry')
    File.write(File.join(root, 'clash-verge.yaml'), YAML.dump(runtime))
    File.write(File.join(profiles, 'uid.yaml'), YAML.dump('proxies' => [node]))
    File.write(File.join(root, 'profiles.yaml'), YAML.dump('current' => 'uid', 'items' => [{ 'uid' => 'uid', 'type' => 'remote', 'file' => 'uid.yaml' }]))
    File.write(File.join(base, 'watchdog-settings.json'), JSON.generate('enabled' => true, 'entryDomain' => 'entry.example.com'))
    signal = { 'schemaVersion' => 1, 'checkedAt' => (@now - 30).iso8601, 'expiresAt' => (@now + 60).iso8601,
               'diagnosis' => { 'state' => 'red' }, 'evidence' => %w[direct localPort clashVersion clashConfigs node].map { |c| { 'category' => c, 'outcome' => 'success' } } +
                 [{ 'category' => 'proxy', 'outcome' => 'timeout' }, { 'category' => 'proxy', 'outcome' => 'failure' }] }
    File.write(File.join(base, 'agent-status.json'), JSON.generate(signal))
    [root, File.join(root, 'clash-verge.yaml'), File.join(profiles, 'uid.yaml')]
  end

  def fake
    FakeWatchdog.new(home: @home, parent_pid: Process.pid, clock: -> { @now })
  end

  def test_successful_run_repairs_runtime_and_profile
    _root, runtime, profile = fixture; wd = fake; wd.verify = true
    assert_equal 'repaired', wd.run(once: true)['state']
    assert_equal '8.8.8.8', YAML.safe_load(File.read(runtime))['proxies'][0]['server']
    assert_equal '8.8.8.8', YAML.safe_load(File.read(profile))['proxies'][0]['server']
    backups = Dir.glob(File.join(@root, 'watchdog-backups', '*', '*.yaml'))
    assert_equal 2, backups.length
    assert backups.all? { |p| File.stat(p).mode & 0777 == 0600 && File.stat(File.dirname(p)).mode & 0777 == 0700 }
    refute_includes File.read(File.join(@root, 'watchdog-status.json')), 'synthetic'
  end

  def test_verification_failure_rolls_back_both_files
    _root, runtime, profile = fixture; wd = fake; wd.verify = false
    assert_equal 'rolled_back', wd.run(once: true)['state']
    assert_equal 'entry.example.com', YAML.safe_load(File.read(runtime))['proxies'][0]['server']
    assert_equal 'entry.example.com', YAML.safe_load(File.read(profile))['proxies'][0]['server']
  end

  def test_outside_edit_during_failed_verification_requires_manual_recovery
    _root, runtime, profile = fixture; wd = fake; wd.verify = false; wd.outside_edit = profile
    assert_equal 'manual_recovery', wd.run(once: true)['state']
    assert_equal "external\n", File.read(profile)
    assert File.file?(File.join(@root, 'watchdog-journal.json'))
  end

  def test_replay_is_throttled
    fixture; wd = fake; wd.verify = true
    assert_equal 'repaired', wd.run(once: true)['state']
    assert_equal 'cooldown', wd.run(once: true)['state']
  end

  def test_freshness_requires_all_base_evidence_and_rejects_expired_or_mixed_signal
    fixture
    signal = JSON.parse(File.read(File.join(@root, 'agent-status.json')))
    signal['evidence'].reject! { |e| e['category'] == 'node' }
    refute @wd.send(:fresh_red_signal?, signal)
    signal['evidence'] << { 'category' => 'node', 'outcome' => 'success' }
    signal['expiresAt'] = (@now + 30).iso8601
    assert @wd.send(:fresh_red_signal?, signal)
    signal['expiresAt'] = (@now - 1).iso8601
    refute @wd.send(:fresh_red_signal?, signal)
  end

  def test_scalar_surgery_preserves_flow_block_and_neighbor
    text = "proxies:\n  - name: 其他节点\n    server: other.example.com\n    flow: xtls-rprx-vision\n  - name: 目标节点\n    server: entry.example.com # keep\n    tls: true\n"
    out = @wd.send(:replace_selected_server, text, '目标节点', '8.8.8.8')
    assert_equal '8.8.8.8', YAML.safe_load(out)['proxies'][1]['server']
    assert_includes out, 'other.example.com'; assert_includes out, 'flow: xtls-rprx-vision'; assert_includes out, '# keep'
  end

  def test_cancel_after_first_write_rolls_back
    _root, runtime, profile = fixture; wd = fake; wd.verify = true; wd.cancel_after_write = true
    assert_equal 'rolled_back', wd.run(once: true)['state']
    assert_equal 'entry.example.com', YAML.safe_load(File.read(runtime))['proxies'][0]['server']
    assert_equal 'entry.example.com', YAML.safe_load(File.read(profile))['proxies'][0]['server']
  end

  def test_config_change_before_write_aborts
    fixture; wd = fake; wd.abort_change = true
    assert_equal 'config_changed', wd.run(once: true)['state']
  end

  def test_private_and_reserved_addresses_are_rejected
    refute @wd.send(:public_ip?, '127.0.0.1')
    refute @wd.send(:public_ip?, '198.51.100.4')
    refute @wd.send(:public_ip?, '10.0.0.1')
  end

  def test_recovery_after_process_death_between_file_writes
    _root, runtime, profile = fixture
    wd = fake; wd.verify = true
    crash = Class.new(Exception)
    wd.define_singleton_method(:atomic_write) do |path, bytes, mode|
      super(path, bytes, mode)
      raise crash if path == runtime
    end
    assert_raises(crash) { wd.run(once: true) }
    assert_equal '8.8.8.8', YAML.safe_load(File.read(runtime))['proxies'][0]['server']
    assert_equal 'entry.example.com', YAML.safe_load(File.read(profile))['proxies'][0]['server']
    assert_equal 'rolled_back', fake.run(once: true)['state']
    assert_equal 'entry.example.com', YAML.safe_load(File.read(runtime))['proxies'][0]['server']
    refute File.exist?(File.join(@root, 'watchdog-journal.json'))
  end

  def test_int_between_file_writes_rolls_back_and_removes_journal
    _root, runtime, profile = fixture
    wd = fake; wd.verify = true
    wd.define_singleton_method(:atomic_write) do |path, bytes, mode|
      super(path, bytes, mode)
      Process.kill('INT', Process.pid) if path == runtime
    end
    assert_equal 'rolled_back', wd.run(once: true)['state']
    assert_equal 'entry.example.com', YAML.safe_load(File.read(runtime))['proxies'][0]['server']
    assert_equal 'entry.example.com', YAML.safe_load(File.read(profile))['proxies'][0]['server']
    refute File.exist?(File.join(@root, 'watchdog-journal.json'))
  end

  def test_attempt_budget_expiry_after_write_cannot_be_swallowed
    _root, runtime, profile = fixture
    wd = fake; wd.verify = true
    raised = false
    wd.define_singleton_method(:atomic_write) do |path, bytes, mode|
      super(path, bytes, mode)
      if path == runtime && !raised
        raised = true
        raise ProxySentry::Watchdog::AttemptExpired
      end
    end
    assert_equal 'rolled_back', wd.run(once: true)['state']
    assert_equal 'entry.example.com', YAML.safe_load(File.read(runtime))['proxies'][0]['server']
    assert_equal 'entry.example.com', YAML.safe_load(File.read(profile))['proxies'][0]['server']
  end

  def test_signal_rejects_future_base_failure_core_failure_and_successful_proxy
    fixture
    signal = JSON.parse(File.read(File.join(@root, 'agent-status.json')))
    assert @wd.send(:fresh_red_signal?, signal)
    %w[direct localPort clashVersion clashConfigs].each do |category|
      changed = Marshal.load(Marshal.dump(signal))
      changed['evidence'].find { |e| e['category'] == category }['outcome'] = 'failure'
      refute @wd.send(:fresh_red_signal?, changed), category
    end
    signal['evidence'] << { 'category' => 'proxy', 'outcome' => 'success' }
    refute @wd.send(:fresh_red_signal?, signal)
    signal['evidence'].pop
    signal['checkedAt'] = (@now + 1).iso8601
    refute @wd.send(:fresh_red_signal?, signal)
  end

  def test_flow_style_surgery_only_replaces_selected_server
    text = "proxies: [{name: 目标节点, server: 'entry.example.com', port: 443}, {name: other, server: other.example}]\n"
    assert_equal text.sub("'entry.example.com'", '8.8.8.8'), @wd.send(:replace_selected_server, text, '目标节点', '8.8.8.8')
  end

  def test_resolver_failure_does_not_drop_other_pools_or_use_environment_proxy
    @wd.define_singleton_method(:resolve_direct) { |_domain, resolver| resolver == '223.5.5.5' ? ['1.1.1.1'] : ['9.9.9.9'] }
    http = Object.new
    %i[use_ssl= open_timeout= read_timeout=].each { |method| http.define_singleton_method(method) { |_| } }
    http.define_singleton_method(:request) do |request|
      raise IOError if request.uri.host == 'dns.google'
      Struct.new(:body).new(JSON.generate('Answer' => [{ 'type' => 1, 'data' => '8.8.8.8' }, { 'type' => 1, 'data' => '127.0.0.1' }]))
    end
    factory = lambda do |_host, _port, proxy|
      assert_nil proxy
      http
    end
    Net::HTTP.stub(:new, factory) do
      assert_equal ['1.1.1.1', '9.9.9.9', '8.8.8.8'], @wd.send(:resolve, 'entry.example.com')
    end
  end

  def test_disabled_cli_accepts_real_argument_order_without_repairing
    helper = File.expand_path('../ProxySentry/watchdog.rb', __dir__)
    assert system('/usr/bin/ruby', '--disable-gems', helper, '--once', '--home', @home, '--parent-pid', Process.pid.to_s)
    status = JSON.parse(File.read(File.join(@root, 'watchdog-status.json')))
    assert_includes %w[disabled legacy_conflict], status['state']
    refute File.exist?(File.join(@root, 'watchdog-journal.json'))
    refute File.exist?(File.join(@root, 'watchdog-settings.json'))
  end

  def test_real_core_accepts_isolated_config_when_explicitly_requested
    core = ENV['PROXYSENTRY_TEST_CORE']
    skip 'Set PROXYSENTRY_TEST_CORE for optional installed-core syntax validation' unless core
    wd = ProxySentry::Watchdog.new(home: @home, core: core)
    node = { 'name' => 'candidate', 'type' => 'vless', 'server' => '8.8.8.8', 'port' => 443,
      'uuid' => '00000000-0000-4000-8000-000000000001', 'tls' => true, 'servername' => 'example.com',
      'client-fingerprint' => 'chrome', 'reality-opts' => { 'public-key' => 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' } }
    bytes = YAML.dump('mode' => 'rule', 'mixed-port' => 0, 'dns' => { 'enable' => false },
      'tun' => { 'enable' => false }, 'proxies' => [node], 'rules' => ['MATCH,candidate'])
    assert wd.send(:validate_config, bytes)
  end

  def test_safe_yaml_rejects_aliases_and_duplicate_keys
    assert_nil ProxySentry::Watchdog.safe_yaml("a: 1\na: 2\n")
    assert_nil ProxySentry::Watchdog.safe_yaml("a: &x 1\nb: *x\n")
    assert_equal({ 'a' => 1 }, ProxySentry::Watchdog.safe_yaml("a: 1\n"))
    assert_equal({ 'external-controller' => ':9097' }, ProxySentry::Watchdog.safe_yaml("external-controller: :9097\n"))
    assert_nil ProxySentry::Watchdog.safe_yaml("a: !ruby/symbol dangerous\n")
  end

  def test_disabled_is_default_and_status_is_sanitized
    path = File.join(@root, 'watchdog-settings.json'); File.write(path, '{"enabled":false,"entryDomain":"secret.example"}')
    out = @wd.run(once: true)
    assert_equal 'disabled', out['state']; refute_includes JSON.generate(out), 'secret'
  end

  def test_probe_uses_isolated_core_and_requires_real_delay_responses
    core = File.join(@home, 'fake-core.rb')
    File.write(core, <<~'RUBY')
      #!/usr/bin/ruby
      require 'socket'
      abort if ENV['PROXYSENTRY_TEST_SENTINEL']
      abort unless File.stat(ARGV[ARGV.index('-f') + 1]).mode & 0777 == 0600
      dir = ARGV[ARGV.index('-d') + 1]
      path = File.join(dir, 'c.sock')
      s = UNIXServer.new(path)
      loop do
        c = s.accept
        c.readpartial(4096) rescue nil
        c.write("HTTP/1.0 200 OK\r\nContent-Length: 11\r\n\r\n{\"delay\":1}")
        c.close
      end
    RUBY
    File.chmod(0755, core)
    wd = ProxySentry::Watchdog.new(home: @home, core: core)
    wd.define_singleton_method(:real_traffic?) { |_port| true }
    node = { 'type' => 'vless', 'network' => 'tcp', 'server' => 'entry.example.com', 'port' => 443,
             'uuid' => 'synthetic', 'reality-opts' => { 'public-key' => 'synthetic' } }
    previous = ENV['PROXYSENTRY_TEST_SENTINEL']
    ENV['PROXYSENTRY_TEST_SENTINEL'] = 'must-not-inherit'
    assert wd.send(:probe_candidate, { 'node' => node }, '8.8.8.8')
  ensure
    ENV['PROXYSENTRY_TEST_SENTINEL'] = previous
  end
end
