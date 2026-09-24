#!/bin/sh
# GL.iNet AGH / OpenClash compatibility installer, version 1.0.0.
# Usage: sh glinet-agh-openclash-compat-1.0.0.sh [install|check|status|uninstall]
set -eu
if [ "$#" -gt 1 ]; then
    echo 'Usage: sh glinet-agh-openclash-compat-1.0.0.sh [install|check|status|uninstall]' >&2
    exit 2
fi
action=${1:-install}
case "$action" in
    --help|-h) echo 'Run on the router: sh glinet-agh-openclash-compat-1.0.0.sh [install|check|status|uninstall]'; exit 0 ;;
    install|check|status|uninstall) ;;
    *) echo 'Unknown action. Use install, check, status, or uninstall.' >&2; exit 2 ;;
esac
test "$(id -u)" = 0 || { echo 'Run as root on the router.' >&2; exit 1; }
test -f /etc/openwrt_release && test -r /tmp/sysinfo/model || {
    echo 'This script must run on the supported OpenWrt/GL.iNet router.' >&2; exit 1;
}
command -v ruby >/dev/null 2>&1 || { echo 'Existing router Ruby/YAML is required.' >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo 'sha256sum is required.' >&2; exit 1; }
umask 077
stage=$(mktemp -d /tmp/router-dns-local.XXXXXX)
cleanup() { rm -rf "$stage"; }
trap cleanup 0
mkdir "$stage/payload"
cat > "$stage/manage.rb" <<'ROUTER_DNS_PAYLOAD_b3397b067983d42372c3473e9970cce0e3e92c0985fe20f330abd9f9b2278b2d'
#!/usr/bin/ruby
require 'yaml'
require_relative 'payload/coordinator'

module RouterDNSPackage
  VERSION = '1.0.0'
  class Error < StandardError; end
  class Manager
    NATIVE = {
      '/etc/init.d/openclash' => '315d674bf3e29ea60bf4b15cb313b35c5689fe14596ed9f3e985620223bddff4',
      '/etc/init.d/adguardhome' => '1be827aef6667c2d8ccd9adeb88e40019be3aa7a96fd0386ab9249aa4fa3db87',
      '/usr/lib/oui-httpd/rpc/adguardhome' => 'c94cf8936bc4219e42b92cdfc700f8392c4abf0569e97fae82d638aaf1e76ecc'
    }.freeze
    CONFIGS = %w[/etc/config/adguardhome /etc/AdGuardHome/config.yaml /etc/config/openclash
                 /etc/config/dhcp /etc/config/firewall /etc/config/gl-dns-v2].freeze
    PAYLOAD = {'/usr/lib/router-dns-coordinator.rb' => 'payload/coordinator.rb',
               '/etc/init.d/router-dns-coordinator' => 'payload/service.init'}.freeze
    HOME = '/etc/router-dns-coordinator'
    BACKUPS = '/root/router-dns-coordinator-backups'

    def initialize(package = __dir__, root = '/')
      @package, @root = File.expand_path(package), File.expand_path(root)
      @system = RouterDNS::System.new
      @patches = @system.parse_config(File.read(File.join(@package, 'patches.yml')))
    end

    def path(name)
      raise Error, 'Invalid absolute path' unless name.start_with?('/') && !name.split('/').include?('..')
      File.join(@root, name.delete_prefix('/'))
    end

    def mkdir(dir)
      return if File.directory?(dir) && !File.symlink?(dir)
      raise Error, "Unsafe directory: #{dir}" if File.exist?(dir) || File.symlink?(dir)
      mkdir(File.dirname(dir))
      Dir.mkdir(dir, 0700)
    end

    def plain_file(file)
      raise Error, "Missing or symlinked file: #{file}" unless File.file?(file) && !File.symlink?(file)
    end

    def digest(file)
      plain_file(file)
      result, ok = command('sha256sum', file)
      raise Error, "Hash failed: #{file}" unless ok && result.match?(/\A[0-9a-f]{64}\s/)
      result.split.first
    end

    def command(*args, timeout: 180)
      @system.run(*args, timeout: timeout)
    end

    def must(*args, timeout: 180)
      output, ok = command(*args, timeout: timeout)
      raise Error, "Command failed: #{args.first(2).join(' ')}" unless ok
      output
    end

    def uci(key)
      command('uci', '-q', 'get', key)[0]
    end

    def atomic(file, data, mode)
      mkdir(File.dirname(file))
      raise Error, "Refusing symlink: #{file}" if File.symlink?(file)
      temp = file + ".new-#{Process.pid}"
      raise Error, "Stale temporary file: #{temp}" if File.exist?(temp) || File.symlink?(temp)
      File.open(temp, File::WRONLY | File::CREAT | File::EXCL, mode) { |f| f.write(data); f.flush; f.fsync }
      File.chmod(mode, temp)
      File.rename(temp, file)
    ensure
      File.unlink(temp) if temp && File.file?(temp) && !File.symlink?(temp)
    end

    def copy(from, to)
      plain_file(from)
      atomic(to, File.binread(from), File.stat(from).mode & 0777)
    end

    def load_yaml(file)
      plain_file(file)
      @system.parse_config(File.read(file))
    end

    def flags
      a, o = uci('adguardhome.config.enabled'), uci('openclash.config.enable')
      raise Error, 'Invalid native enable flags' unless [a,o].all? { |x| %w[0 1].include?(x) }
      {'agh' => a, 'oc' => o}
    end

    def targets
      CONFIGS + @patches.map { |p| p['path'] } + PAYLOAD.keys
    end

    def fingerprint(names = targets)
      names.to_h do |name|
        file = path(name)
        [name, File.exist?(file) ? {'sha256' => digest(file), 'mode' => File.stat(file).mode & 0777} : nil]
      end
    end

    def verify_bundle
      expected = %w[manage.rb install.sh patches.yml payload/coordinator.rb payload/service.init]
      lines = File.readlines(File.join(@package, 'SHA256SUMS')).map(&:strip)
      raise Error, 'Invalid package manifest' unless lines.length == expected.length
      lines.each do |line|
        hash, name = line.split(/\s+/, 2)
        raise Error, 'Invalid package manifest path' unless expected.delete(name) && hash.match?(/\A[0-9a-f]{64}\z/)
        raise Error, "Package checksum mismatch: #{name}" unless digest(File.join(@package, name)) == hash
      end
      raise Error, 'Incomplete package manifest' unless expected.empty?
    end

    def preflight
      verify_bundle
      raise Error, 'Only the validated GL-MT5000 platform is supported' unless File.read(path('/tmp/sysinfo/model')).strip == 'GL.iNet GL-MT5000'
      raise Error, 'Only the validated GL.iNet 4.9.0 build is supported' unless File.read(path('/etc/glversion')).strip == '4.9.0'
      NATIVE.each { |name, hash| raise Error, "Unsupported native version: #{name}" unless digest(path(name)) == hash }
      %w[uci ubus timeout dig netstat iptables ip6tables pidof pgrep sha256sum].each do |name|
        raise Error, "Missing dependency: #{name}" unless ENV.fetch('PATH').split(':').any? { |dir| File.executable?(File.join(dir, name)) }
      end
      raise Error, 'Only fw3/iptables is supported' if File.executable?(path('/sbin/fw4'))
      raise Error, 'Requires one dnsmasq instance' unless Dir.glob(path('/var/etc/dnsmasq.conf.*')).length == 1
      raise Error, 'Requires Fake-IP Mix and native DNS redirect' unless uci('openclash.config.en_mode') == 'fake-ip-mix' && uci('openclash.config.enable_redirect_dns') == '1'
      raise Error, 'AGH Handle Client Requests must be off' unless ['', '0'].include?(uci('adguardhome.config.dns_enabled'))
      raise Error, 'GL DNS mode must be auto' unless uci('gl-dns-v2.@dns[0].mode') == 'auto'
      raise Error, 'Custom per-domain dnsmasq servers need manual review; no settings changed' if uci('dhcp.@dnsmasq[0].server').split.any? { |value| value.start_with?('/') }
      config = load_yaml(path('/etc/AdGuardHome/config.yaml'))
      raise Error, 'AGH must listen on DNS port 3053' unless config.dig('dns', 'port') == 3053
      raise Error, 'Custom per-domain AGH upstreams need manual review; no settings changed' if Array(config.dig('dns', 'upstream_dns')).any? { |value| value.start_with?('[/') }
      raise Error, 'An AGH upstream file is configured; review it before installation' unless config.dig('dns', 'upstream_dns_file').to_s.empty?
      flags
      CONFIGS.each { |name| plain_file(path(name)) }
      original = @patches.all? { |p| digest(path(p['path'])) == p['original_sha256'] }
      patched = @patches.all? { |p| digest(path(p['path'])) == p['patched_sha256'] }
      payload_present = PAYLOAD.keys.any? { |name| File.exist?(path(name)) || File.symlink?(path(name)) }
      payload_exact = PAYLOAD.all? { |name, src| File.file?(path(name)) && digest(path(name)) == digest(File.join(@package, src)) && (File.stat(path(name)).mode & 0777) == 0755 }
      @patches.each { |p| raise Error, "Unexpected permissions: #{p['path']}" unless (File.stat(path(p['path'])).mode & 0777) == p['mode'] }
      mode = if original && !payload_present
               'fresh'
             elsif patched && payload_exact
               'installed'
             else
               raise Error, 'Unknown, modified or partially installed compatibility files; nothing changed'
             end
      receipt_file = path(HOME + '/state.yml')
      if File.exist?(receipt_file)
        receipt = load_yaml(receipt_file)
        raise Error, 'Unsupported or incomplete installation receipt' unless receipt['version'] == VERSION && receipt['phase'] == 'installed' && mode == 'installed'
      elsif File.exist?(path(HOME))
        raise Error, 'Incomplete management directory; preserve it for recovery'
      end
      { 'mode' => mode, 'flags' => flags, 'version' => VERSION }
    end

    def with_lock
      lock = path('/tmp/router-dns-installer.lock')
      Dir.mkdir(lock, 0700)
      begin
        yield
      ensure
        Dir.rmdir(lock)
      end
    rescue Errno::EEXIST
      raise Error, 'Another installer is running, or a stale lock needs inspection'
    end

    def snapshot(label, initial_flags = flags)
      mkdir(path(BACKUPS))
      backup = path(BACKUPS + "/#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{Process.pid}-#{label}")
      mkdir(backup)
      entries = fingerprint
      entries.each { |name, item| copy(path(name), backup + '/files' + name) if item }
      manifest = {'version' => VERSION, 'flags' => initial_flags, 'files' => entries}
      atomic(backup + '/snapshot.yml', YAML.dump(manifest), 0600)
      backup
    end

    def verified_snapshot(backup, preserve_agh: false)
      raise Error, 'Backup is outside the managed backup directory' unless backup.start_with?(path(BACKUPS) + '/') && !backup.include?('/../')
      manifest = load_yaml(backup + '/snapshot.yml')
      raise Error, 'Invalid backup targets' unless manifest['files'].keys.sort == targets.sort
      raise Error, 'Invalid backup flags' unless %w[agh oc].all? { |k| %w[0 1].include?(manifest.dig('flags', k)) }
      manifest['files'].each do |name, item|
        next unless item
        next if preserve_agh && name == '/etc/AdGuardHome/config.yaml'
        file = backup + '/files' + name
        raise Error, "Backup changed: #{name}" unless digest(file) == item['sha256'] && (File.stat(file).mode & 0777) == item['mode']
      end
      manifest
    end

    def service(name, action)
      must('/etc/init.d/' + name, action)
    end

    def checkpoint_agh(backup)
      manifest = verified_snapshot(backup)
      name = '/etc/AdGuardHome/config.yaml'
      copy(path(name), backup + '/files' + name)
      manifest['files'][name] = {'sha256' => digest(path(name)), 'mode' => File.stat(path(name)).mode & 0777}
      atomic(backup + '/snapshot.yml', YAML.dump(manifest), 0600)
    end

    def stop_native(checkpoint: nil)
      service('adguardhome', 'stop')
      30.times do
        break if command('pidof', 'AdGuardHome')[0].empty?
        sleep 0.2
      end
      raise Error, 'AGH did not finish stopping' unless command('pidof', 'AdGuardHome')[0].empty?
      # Save AGH's shutdown flush before any later operation can fail.
      checkpoint_agh(checkpoint) if checkpoint
      service('openclash', 'stop')
      raise Error, 'Native processes did not stop' unless command('pidof', 'AdGuardHome')[0].empty? && command('pidof', 'clash')[0].empty?
    end

    def start_native(wanted)
      service('dnsmasq', 'restart')
      service('firewall', 'reload')
      service('adguardhome', 'start') if wanted['agh'] == '1'
      service('openclash', 'start') if wanted['oc'] == '1'
    end

    def native_healthy(wanted)
      return false unless flags == wanted && @system.dns_healthy?(53)
      {'agh' => ['AdGuardHome',3053], 'oc' => ['clash',7874]}.each do |key,(name,port)|
        if wanted[key] == '1'
          return false unless @system.live?(name,port) && @system.dns_healthy?(port)
        else
          return false unless command('pidof',name)[0].empty?
        end
      end
      tcp, ok = command('dig','+time=2','+tries=1','+tcp','@127.0.0.1','example.com','A','+short', timeout: 8)
      ok && tcp.lines.any? { |line| line.strip.match?(/\A\d+(?:\.\d+){3}\z/) && !line.start_with?('0.', '127.') }
    end

    def wait_native(wanted)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 180
      loop do
        return true if native_healthy(wanted)
        raise Error, 'Native enable flags changed during recovery' unless flags == wanted
        raise Error, 'Native services or DNS did not recover within 180 seconds' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 2
      end
    end

    def healthy(wanted)
      return false unless flags == wanted
      return false unless command('/etc/init.d/router-dns-coordinator', 'running')[1]
      return false unless command('/etc/init.d/router-dns-coordinator', 'enabled')[1]
      status = load_yaml(path('/tmp/router-dns-coordinator.status'))
      return false unless status['adguard_requested'] == (wanted['agh'] == '1') && status['openclash_requested'] == (wanted['oc'] == '1')
      return false unless status['degraded'] == [] && status['adguard_ready'] == (wanted['agh'] == '1') && status['openclash_listening'] == (wanted['oc'] == '1')
      return false unless @system.dns_healthy?(53)
      return false if wanted['oc'] == '1' && command('pgrep', '-f', '^/bin/sh /usr/share/openclash/openclash_watchdog.sh')[0].empty?
      true
    rescue Error, Errno::ENOENT
      false
    end

    def wait_healthy(wanted)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 180
      loop do
        return true if healthy(wanted)
        raise Error, 'Native enable flags changed during installation; preserve user intent and inspect backup' unless flags == wanted
        raise Error, 'Installation health check did not converge within 180 seconds' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 2
      end
    end

    def guard_native_files
      NATIVE.each { |name, hash| raise Error, "Native file changed during operation: #{name}" unless digest(path(name)) == hash }
      @patches.each do |patch|
        raise Error, "Patch target changed during operation: #{patch['path']}" unless [patch['original_sha256'],patch['patched_sha256']].include?(digest(path(patch['path'])))
      end
      PAYLOAD.each do |name, source|
        next unless File.exist?(path(name)) || File.symlink?(path(name))
        raise Error, "Installed payload changed during operation: #{name}" unless digest(path(name)) == digest(File.join(@package, source))
      end
    end

    def restore(backup, preserve_agh: false)
      manifest = verified_snapshot(backup, preserve_agh: preserve_agh)
      guard_native_files
      if File.file?(path('/etc/init.d/router-dns-coordinator'))
        service('router-dns-coordinator', 'stop')
        service('router-dns-coordinator', 'disable')
      end
      stop_native
      manifest['files'].each do |name, item|
        next if preserve_agh && name == '/etc/AdGuardHome/config.yaml'
        if item
          copy(backup + '/files' + name, path(name))
        elsif PAYLOAD.key?(name) && File.file?(path(name))
          File.unlink(path(name))
        end
      end
      start_native(manifest['flags'])
      wait_native(manifest['flags'])
      manifest
    end

    def record(backup, kind, wanted)
      receipt = {'version' => VERSION, 'phase' => 'installed', 'kind' => kind,
                 'backup' => backup, 'flags_at_install' => wanted,
                 'installed_files' => fingerprint, 'created_at' => Time.now.utc.to_s}
      atomic(path(HOME + '/state.yml'), YAML.dump(receipt), 0600)
      receipt
    end

    def adopt(wanted)
      # Only this earlier, verified manual deployment can be adopted. No guessed backups.
      pointer = path('/root/codex-backups/native-ui-toggle-current')
      legacy = File.read(pointer).strip
      raise Error, 'Unrecognized legacy backup path' unless legacy.match?(%r{\A/root/codex-backups/\d{8}-\d{6}-native-ui-toggle\z})
      legacy = path(legacy)
      NATIVE.select { |name, _| name.start_with?('/etc/init.d/') }.each { |name, hash| raise Error, "Legacy native backup mismatch: #{name}" unless digest(legacy + '/files' + name) == hash }
      @patches.each { |p| raise Error, 'Legacy patch backup mismatch' unless digest(legacy + '/files' + p['path']) == p['original_sha256'] }
      # Check backup integrity against its recorded hashes; this is not a cryptographic signature.
      hashes = File.readlines(legacy + '/before.sha256').map { |l| l.strip.split(/\s+/, 2).reverse }.to_h
      CONFIGS.each { |name| raise Error, "Legacy configuration backup mismatch: #{name}" unless hashes[name] && digest(legacy + '/files' + name) == hashes[name] }
      raise Error, 'Existing deployment is not healthy; adoption makes no service changes' unless healthy(wanted)
      backup = snapshot('adopt')
      manifest = verified_snapshot(backup)
      (CONFIGS + @patches.map { |p| p['path'] }).each do |name|
        copy(legacy + '/files' + name, backup + '/files' + name)
        file = backup + '/files' + name
        manifest['files'][name] = {'sha256' => digest(file), 'mode' => File.stat(file).mode & 0777}
      end
      PAYLOAD.each_key { |name| manifest['files'][name] = nil }
      manifest['flags'] = {
        'agh' => must('uci', '-c', legacy + '/files/etc/config', '-q', 'get', 'adguardhome.config.enabled'),
        'oc' => must('uci', '-c', legacy + '/files/etc/config', '-q', 'get', 'openclash.config.enable')
      }
      atomic(backup + '/snapshot.yml', YAML.dump(manifest), 0600)
      verified_snapshot(backup)
      record(backup, 'adopted-manual-deployment', wanted)
      puts 'ADOPTED: existing verified deployment registered; no services restarted.'
    end

    def install
      with_lock do
        info = preflight
        if info['mode'] == 'installed'
          if File.file?(path(HOME + '/state.yml'))
            raise Error, 'Installed files match but service health failed; no automatic restart performed' unless healthy(info['flags'])
            puts 'ALREADY_INSTALLED: checksums and current service health verified; no changes.'
          else
            adopt(info['flags'])
          end
          return
        end
        wanted = info['flags']
        backup = snapshot('install', wanted)
        # Persist recovery location before any service or configuration change.
        atomic(path(HOME + '/transaction.yml'), YAML.dump({'backup' => backup, 'phase' => 'installing'}), 0600)
        managed_agh = false
        begin
          stop_native(checkpoint: backup)
          raise Error, 'Enable flags changed; refusing to apply stale installation' unless flags == wanted
          @patches.each do |patch|
            file = path(patch['path'])
            raise Error, "Native patch target changed: #{patch['path']}" unless digest(file) == patch['original_sha256']
            data = File.read(file)
            patch['edits'].each do |edit|
              raise Error, 'Patch context is not unique' unless data.scan(Regexp.new(Regexp.escape(edit['before']))).length == 1
              data = data.sub(edit['before'], edit['after'])
            end
            atomic(file, data, patch['mode'])
            raise Error, 'Patched checksum mismatch' unless digest(file) == patch['patched_sha256']
          end
          PAYLOAD.each { |name, src| atomic(path(name), File.binread(File.join(@package, src)), 0755) }
          must('ruby', '-c', path('/usr/lib/router-dns-coordinator.rb'))
          must('sh', '-n', path('/usr/share/openclash/openclash_watchdog.sh'))
          service('router-dns-coordinator', 'enable')
          start_native(wanted)
          managed_agh = true
          service('router-dns-coordinator', 'start')
          wait_healthy(wanted)
          record(backup, 'fresh-install', wanted)
          File.unlink(path(HOME + '/transaction.yml'))
          puts "INSTALLED #{VERSION}; backup: #{backup}"
        rescue StandardError => error
          # If a user changed a flag concurrently, keep that intent when restoring files.
          current_flags = flags rescue wanted
          begin
            restore(backup, preserve_agh: !managed_agh)
            if current_flags != wanted
              must('uci', 'set', 'adguardhome.config.enabled=' + current_flags['agh'])
              must('uci', 'set', 'openclash.config.enable=' + current_flags['oc'])
              must('uci', 'commit', 'adguardhome'); must('uci', 'commit', 'openclash')
              stop_native; start_native(current_flags); wait_native(current_flags)
            end
            File.unlink(path(HOME + '/transaction.yml')) if File.file?(path(HOME + '/transaction.yml'))
            File.unlink(path(HOME + '/state.yml')) if File.file?(path(HOME + '/state.yml'))
            Dir.rmdir(path(HOME)) if Dir.empty?(path(HOME))
            raise Error, "Install failed and backup was restored: #{error.message}"
          rescue Error => recovery_error
            raise recovery_error if recovery_error.message.start_with?('Install failed and backup was restored:')
            raise Error, "RECOVERY_REQUIRED: #{backup}; original error: #{error.message}; restore error: #{recovery_error.message}"
          end
        end
      end
    end

    def uninstall
      with_lock do
        preflight
        wanted = flags
        receipt = load_yaml(path(HOME + '/state.yml'))
        manifest = verified_snapshot(receipt['backup'])
        emergency = snapshot('before-uninstall')
        puts "Saved current state before uninstall: #{emergency}"
        managed_agh = false
        begin
          service('router-dns-coordinator', 'stop')
          service('router-dns-coordinator', 'disable')
          stop_native(checkpoint: emergency)
          # Restore only owned DNS settings, keeping current filters, logs,
          # subscriptions and unrelated user configuration from later use.
          current = load_yaml(path('/etc/AdGuardHome/config.yaml'))
          original = load_yaml(receipt['backup'] + '/files/etc/AdGuardHome/config.yaml')
          %w[upstream_dns upstream_dns_file fallback_dns cache_ttl_min cache_optimistic].each do |key|
            if original['dns'].key?(key)
              current['dns'][key] = original['dns'][key]
            else
              current['dns'].delete(key)
            end
          end
          added = ['127.0.0.1', '::1'] - Array(original['dns']['ratelimit_whitelist'])
          current['dns']['ratelimit_whitelist'] = Array(current['dns']['ratelimit_whitelist']) - added
          file = path('/etc/AdGuardHome/config.yaml')
          candidate = file + '.uninstall-check'
          atomic(candidate, YAML.dump(current), File.stat(file).mode & 0777)
          must('/usr/bin/AdGuardHome', '--check-config', '--glinet', '-c', candidate, '-w', '/etc/AdGuardHome')
          managed_agh = true
          File.rename(candidate, file)
          %w[server noresolv localuse cachesize resolvfile].each do |key|
            target = 'dhcp.@dnsmasq[0].' + key
            value, found = command('uci', '-c', receipt['backup'] + '/files/etc/config', '-q', 'get', target)
            command('uci', '-q', 'delete', target)
            if found
              if key == 'server'
                value.split.each { |server| must('uci', 'add_list', target + '=' + server) }
              else
                must('uci', 'set', target + '=' + value)
              end
            end
          end
          must('uci', 'commit', 'dhcp')
          @patches.each do |p|
            raise Error, "Patch target changed before uninstall: #{p['path']}" unless digest(path(p['path'])) == p['patched_sha256']
            copy(receipt['backup'] + '/files' + p['path'], path(p['path']))
          end
          PAYLOAD.each_key { |name| File.unlink(path(name)) }
          raise Error, 'Enable flags changed during uninstall' unless flags == wanted
          start_native(wanted)
          wait_native(wanted)
        rescue StandardError => error
          begin
            restore(emergency, preserve_agh: !managed_agh)
            service('router-dns-coordinator', 'enable')
            service('router-dns-coordinator', 'start')
            wait_healthy(verified_snapshot(emergency)['flags'])
          rescue StandardError => restore_error
            raise Error, "RECOVERY_REQUIRED: #{emergency}; #{error.message}; restore: #{restore_error.message}"
          end
          raise Error, "Uninstall failed; prior installed state restored: #{error.message}"
        end
        File.unlink(path(HOME + '/state.yml'))
        Dir.rmdir(path(HOME)) if Dir.empty?(path(HOME))
        puts 'UNINSTALLED: owned DNS settings and original patch files restored; current native enable flags, filters, subscriptions and disk logs retained.'
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    raise RouterDNSPackage::Error, 'Run as root on the router' unless Process.uid.zero?
    manager = RouterDNSPackage::Manager.new
    case ARGV[0] || 'check'
    when 'check', 'status'
      result = manager.preflight
      puts YAML.dump(result.merge('healthy' => result['mode'] == 'installed' ? manager.healthy(result['flags']) : nil))
    when 'install' then manager.install
    when 'uninstall' then manager.uninstall
    else raise RouterDNSPackage::Error, 'Usage: sh install.sh [check|install|status|uninstall]'
    end
  rescue StandardError => error
    warn "STOP: #{error.class}: #{error.message}"
    exit 1
  end
end
ROUTER_DNS_PAYLOAD_b3397b067983d42372c3473e9970cce0e3e92c0985fe20f330abd9f9b2278b2d
cat > "$stage/install.sh" <<'ROUTER_DNS_PAYLOAD_a2c06a5b982ef0d7e81f08930b431e02686cba8daadaf2756d5627d957fdffdc'
#!/bin/sh
set -eu
package_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
test "$(id -u)" = 0 || { echo 'Run this script as root on the router.' >&2; exit 1; }
command -v ruby >/dev/null 2>&1 || { echo 'Ruby is required; no packages were installed automatically.' >&2; exit 1; }
exec ruby "$package_dir/manage.rb" "${1:-check}"
ROUTER_DNS_PAYLOAD_a2c06a5b982ef0d7e81f08930b431e02686cba8daadaf2756d5627d957fdffdc
cat > "$stage/patches.yml" <<'ROUTER_DNS_PAYLOAD_85e5ccf8d18b39bf5c294028ee0ffa0947ee382c9a77d34301051b5e8f35cd42'
[
  {
    "path": "/usr/share/openclash/openclash_watchdog.sh",
    "original_sha256": "b59cb35c42e94d6d860adf8fa43c257345ff113a7915846a50cdc35d75b5cb91",
    "patched_sha256": "06d3bc63893d1939ca3f25763319e2f57cbf8dee69bac8dd7e556e6f3ce3ee74",
    "mode": 493,
    "edits": [
      {
        "before": "## DNS转发劫持\n   if [ \"$enable_redirect_dns\" = \"1\" ]; then\n      if [ -z \"$(uci -q get dhcp.@dnsmasq[0].server |grep \"$dns_port\")\" ] || [ ! -z \"$(uci -q get dhcp.@dnsmasq[0].server |awk -F ' ' '{print $2}')\" ]; then\n",
        "after": "## DNS转发劫持\n   # The router coordinator owns DNS while active; avoid resetting its AGH upstream.\n   if [ \"$enable_redirect_dns\" = \"1\" ] && ! /etc/init.d/router-dns-coordinator running 2>/dev/null; then\n      if [ -z \"$(uci -q get dhcp.@dnsmasq[0].server |grep \"$dns_port\")\" ] || [ ! -z \"$(uci -q get dhcp.@dnsmasq[0].server |awk -F ' ' '{print $2}')\" ]; then\n"
      }
    ]
  },
  {
    "path": "/etc/firewall.nat6",
    "original_sha256": "69f5fc1fee8079a52a62afbfb09521a41c26a3850922cffe44f2a35a99f6ab4c",
    "patched_sha256": "9b4a2e9e8d36046d29dfff60bce09634eedc475f10741f7748e8665e58e50ac2",
    "mode": 493,
    "edits": [
      {
        "before": "nat6_init() {\n    iptables-save -t nat \\\n    | sed -e \"/\\s[DS]NAT\\s/d;/\\sMASQUERADE$/d\" \\\n    | ip6tables-restore -w -T nat\n",
        "after": "nat6_init() {\n    # OpenClash installs IPv6 rules itself; never translate its IPv4 chains.\n    iptables-save -t nat \\\n    | sed -e \"/\\s[DS]NAT\\s/d;/\\sMASQUERADE$/d;/[Oo]pen[Cc]lash/d\" \\\n    | ip6tables-restore -w -T nat\n"
      }
    ]
  }
]
ROUTER_DNS_PAYLOAD_85e5ccf8d18b39bf5c294028ee0ffa0947ee382c9a77d34301051b5e8f35cd42
cat > "$stage/payload/coordinator.rb" <<'ROUTER_DNS_PAYLOAD_ab832053346a87daa3063d9d854f92eee8d7a0dcd905bfdd1faf130301d8edac'
#!/usr/bin/ruby
# Coordinates existing GL.iNet and OpenClash switches; does not own their flags.
require 'yaml'

module RouterDNS
  class System
    def run(*args, timeout: 8)
      output = IO.popen(['timeout', timeout.to_s, *args], err: '/dev/null', &:read)
      [output.strip, $?.success?]
    rescue StandardError
      ['', false]
    end

    def get(key)
      run('uci', '-q', 'get', key)[0]
    end

    def parse_config(text)
      # AGH emits unquoted IPv6 such as ::1. Ruby's YAML 1.1 loader treats
      # that as a Symbol, whereas AGH reads the original scalar as a string.
      normalize = lambda do |value|
        case value
        when Symbol then ':' + value.to_s
        when Array then value.map { |item| normalize.call(item) }
        when Hash then value.to_h { |key, item| [normalize.call(key), normalize.call(item)] }
        else value
        end
      end
      normalize.call(YAML.load(text))
    end

    def live?(name, port)
      return false if run('pidof', name)[0].empty?
      lines = run('netstat', '-lntu')[0]
      %w[tcp udp].all? do |protocol|
        lines.each_line.any? { |line| line.start_with?(protocol) && line.match?(/:#{port}\s/) }
      end
    end

    def direct_servers
      path = '/tmp/resolv.conf.d/resolv.conf.auto'
      return [] unless File.file?(path)
      lan = get('network.lan.ipaddr').split('/').first
      addresses = File.readlines(path).map do |line|
        address = line.split
        next unless address[0] == 'nameserver'
        ip = address[1]
        next unless ip && ip.match?(/\A\d{1,3}(?:\.\d{1,3}){3}\z/)
        next if ip == lan || ip.start_with?('127.', '0.', '198.18.', '198.19.')
        ip
      end.compact.uniq
      now = Time.now.to_i
      retry_after = @direct_selected && !@direct_selected.empty? ? 300 : 10
      return @direct_selected if @direct_candidates == addresses && @direct_checked_at && now - @direct_checked_at < retry_after
      # The upstream gateway on this LAN refuses TCP DNS. Keep WAN DNS when
      # it supports both transports; otherwise use the verified public backup.
      selected = (addresses + ['223.5.5.5']).uniq.find do |address|
        [[], ['+tcp']].all? do |extra|
          output, ok = run('dig', '+time=2', '+tries=1', '@' + address,
                           'www.baidu.com', 'A', '+short', *extra)
          ok && output.lines.any? { |line| line.strip.match?(/\A\d{1,3}(?:\.\d{1,3}){3}\z/) }
        end
      end
      @direct_candidates, @direct_checked_at = addresses, now
      @direct_selected = selected ? [selected] : []
    end

    def agh_upstream(servers, refresh = false)
      path = '/etc/AdGuardHome/config.yaml'
      wanted = {
        'upstream_dns' => servers, 'upstream_dns_file' => '', 'fallback_dns' => [],
        'cache_ttl_min' => 0, 'cache_optimistic' => false
      }
      config = parse_config(File.read(path))
      # dnsmasq aggregates LAN clients behind loopback. Do not apply the
      # per-client 20 qps limit to that combined stream; retain other limits.
      wanted['ratelimit_whitelist'] = (Array(config['dns']['ratelimit_whitelist']) + ['127.0.0.1', '::1']).uniq
      return true if !refresh && wanted.all? { |key, value| config['dns'][key] == value }
      now = Time.now.to_i
      return false if @agh_restart_at && now - @agh_restart_at < 15
      # Keep port 53 on a verified alternate path while AGH stops and flushes
      # its disk query log. No web session or permanent API credential is used.
      fallback = servers == ['127.0.0.1:7874'] ? '127.0.0.1#7874' : servers.first + '#53'
      return false unless route(fallback)
      return false unless get('adguardhome.config.enabled') == '1'
      @agh_restart_at = now
      return false unless run('/etc/init.d/adguardhome', 'stop', timeout: 120)[1]
      30.times do
        break if run('pidof', 'AdGuardHome')[0].empty?
        sleep 0.1
      end
      return false unless run('pidof', 'AdGuardHome')[0].empty?
      # Read after shutdown: AGH writes its current settings when it exits.
      original = File.binread(path)
      config = parse_config(original)
      wanted.each { |key, value| config['dns'][key] = value }
      metadata = File.stat(path)
      candidate = path + '.coordinator.new'
      File.open(candidate, 'w', metadata.mode & 0777) { |file| file.write(YAML.dump(config)) }
      File.chown(metadata.uid, metadata.gid, candidate)
      valid = run('/usr/bin/AdGuardHome', '--check-config', '--glinet',
                  '-c', candidate, '-w', '/etc/AdGuardHome', timeout: 20)[1]
      if valid
        File.rename(candidate, path)
      else
        File.unlink(candidate) if File.exist?(candidate)
      end
      return false unless get('adguardhome.config.enabled') == '1'
      started = run('/etc/init.d/adguardhome', 'start', timeout: 120)[1]
      return false unless valid && started
      40.times do
        return false unless get('adguardhome.config.enabled') == '1'
        return true if live?('AdGuardHome', 3053)
        sleep 0.25
      end
      false
    rescue StandardError
      false
    end

    def dns_healthy?(port, direct = false)
      result, ok = run('dig', '+time=2', '+tries=1', '@127.0.0.1', '-p', port.to_s, 'example.com', 'A', '+short')
      return false unless ok
      addresses = result.lines.map(&:strip).select { |line| line.match?(/\A\d{1,3}(?:\.\d{1,3}){3}\z/) }
      addresses.any? do |address|
        !address.start_with?('0.', '127.') && (!direct || !address.start_with?('198.18.', '198.19.'))
      end
    end

    def reconcile_agh(wanted)
      actual = !run('pidof', 'AdGuardHome')[0].empty?
      if actual == wanted
        @agh_mismatch_since = nil
        return
      end
      now = Time.now.to_i
      @agh_mismatch_since ||= now
      return if now - @agh_mismatch_since < 8
      return if @agh_service_at && now - @agh_service_at < 15
      return unless (get('adguardhome.config.enabled') == '1') == wanted
      @agh_service_at = now
      run('/etc/init.d/adguardhome', wanted ? 'start' : 'stop', timeout: 120)
    end

    def route(server)
      base = 'dhcp.@dnsmasq[0].'
      wanted = {
        'server' => server, 'noresolv' => server.empty? ? '0' : '1',
        'localuse' => '1', 'cachesize' => '0',
        'resolvfile' => server.empty? ? '/tmp/resolv.conf.d/resolv.conf.auto' : ''
      }
      changed = false
      wanted.each do |key, value|
        next if get(base + key) == value
        success = if value.empty?
                    run('uci', '-q', 'delete', base + key)[1]
                  elsif key == 'server'
                    run('uci', '-q', 'delete', base + key)
                    run('uci', 'add_list', base + key + '=' + value)[1]
                  else
                    run('uci', 'set', base + key + '=' + value)[1]
                  end
        return false unless success
        changed = true
      end
      return false if changed && !run('uci', 'commit', 'dhcp')[1]
      now = Time.now.to_i
      @route_recovery_attempted = nil if changed
      if !changed && runtime_route?(server)
        return true if @route_health_server == server && @route_health_at && now - @route_health_at < 15
        if dns_healthy?(53)
          @route_health_server, @route_health_at = server, now
          @route_recovery_attempted = nil
          return true
        end
        # One recovery attempt can fix a stuck dnsmasq. An unchanged route
        # with an unavailable upstream must not cause endless restarts.
        return false if @route_recovery_attempted == server
      end
      # Never restart continuously when a persistent configuration error exists.
      return false if @restart_at && now - @restart_at < 10
      @restart_at = now
      @route_recovery_attempted = server
      return false unless run('/etc/init.d/dnsmasq', 'restart', timeout: 120)[1]
      healthy = runtime_route?(server) && dns_healthy?(53)
      @route_health_server, @route_health_at = server, now if healthy
      @route_recovery_attempted = nil if healthy
      healthy
    end

    def runtime_route?(server)
      files = Dir.glob('/var/etc/dnsmasq.conf.*')
      return false unless files.length == 1
      lines = File.readlines(files[0]).map(&:strip)
      servers = lines.grep(/\Aserver=/)
      expected = server.empty? ? [] : ['server=' + server]
      servers == expected && lines.include?('no-resolv') == !server.empty? &&
        !run('pidof', 'dnsmasq')[0].empty?
    end

    def firewall_ready?
      nat, nat_ok = run('iptables', '-t', 'nat', '-S', 'openclash')
      mangle, mangle_ok = run('iptables', '-t', 'mangle', '-S', 'openclash')
      hook, hook_ok = run('iptables', '-t', 'mangle', '-S', 'PREROUTING')
      good = nat_ok && nat.include?('-j REDIRECT') && mangle_ok && mangle.include?('-j MARK') &&
             hook_ok && hook.include?('-j openclash')
      if get('openclash.config.ipv6_enable') == '1'
        v6, v6_ok = run('ip6tables', '-t', 'mangle', '-S', 'openclash')
        good &&= v6_ok && v6.include?('-j MARK')
      end
      good
    end

    def repair_firewall
      run('/etc/init.d/openclash', 'reload', 'manual', timeout: 120)[1]
    end

    def status(value)
      File.write('/tmp/router-dns-coordinator.status.new', YAML.dump(value))
      File.rename('/tmp/router-dns-coordinator.status.new', '/tmp/router-dns-coordinator.status')
    end

    def log(message)
      run('logger', '-t', 'router-dns-coordinator', message)
    end
  end

  class Coordinator
    def initialize(system)
      @system = system
      @upstream_key = nil
      @last_status = nil
      @missing_firewall_since = nil
      @last_firewall_repair = -60
      @oc_health_key = nil
      @oc_health_at = -10
      @oc_healthy = false
      @agh_health_at = -10
      @agh_healthy = false
      @observed_upstream = nil
      @upstream_stable_since = nil
    end

    def tick(now = Time.now.to_i)
      s = @system
      agh_wanted = s.get('adguardhome.config.enabled') == '1'
      oc_wanted = s.get('openclash.config.enable') == '1'
      oc_live = oc_wanted && s.live?('clash', 7874)
      agh_live = agh_wanted && s.live?('AdGuardHome', 3053)
      if oc_live
        oc_key = s.run('pidof', 'clash')[0]
        if oc_key != @oc_health_key || now - @oc_health_at >= 10
          @oc_healthy = s.dns_healthy?(7874)
          @oc_health_at = now
          @oc_health_key = oc_key
        end
        oc_live &&= @oc_healthy
      else
        @oc_health_key = nil
      end
      direct = s.direct_servers
      upstream = oc_live ? ['127.0.0.1:7874'] : direct
      reason = []
      observed = [upstream, oc_live ? @oc_health_key : nil]
      if observed != @observed_upstream
        @observed_upstream = observed
        @upstream_stable_since = now
      end

      if oc_live && !s.firewall_ready?
        @missing_firewall_since ||= now
        if now - @missing_firewall_since >= 20 && now - @last_firewall_repair >= 60
          s.repair_firewall
          @last_firewall_repair = now
        end
        reason << 'OpenClash firewall is starting or being restored'
      else
        @missing_firewall_since = nil
      end

      agh_usable = false
      if agh_live && !upstream.empty? && now - @upstream_stable_since >= 4
        # A restart, even with the same upstream, must be checked afresh.
        key = [s.run('pidof', 'AdGuardHome')[0], upstream, oc_live ? @oc_health_key : nil]
        refresh = @upstream_key && @upstream_key[0] == key[0] && @upstream_key != key
        if s.agh_upstream(upstream, !!refresh)
          key[0] = s.run('pidof', 'AdGuardHome')[0]
          if @upstream_key != key
            @upstream_key = key
            @agh_healthy = s.dns_healthy?(3053, !oc_live)
            @agh_health_at = now
          elsif now - @agh_health_at >= 10
            @agh_healthy = s.dns_healthy?(3053, !oc_live)
            @agh_health_at = now
          end
          agh_usable = @agh_healthy
        end
      end
      @upstream_key = nil unless agh_live

      server = if agh_usable
                 '127.0.0.1#3053'
               elsif oc_live
                 '127.0.0.1#7874'
               else
                 direct.empty? ? '' : direct.first + '#53'
               end
      reason << 'AdGuard Home is not yet ready; DNS temporarily bypasses it' if agh_wanted && !agh_usable
      reason << 'OpenClash is not yet ready; using direct DNS temporarily' if oc_wanted && !oc_live
      reason << 'No usable IPv4 WAN DNS for AdGuard Home' if agh_live && upstream.empty?

      # A UI may change flags during a readiness check. Never apply that stale
      # decision; the next tick recomputes the complete desired state.
      return if (s.get('adguardhome.config.enabled') == '1') != agh_wanted
      return if (s.get('openclash.config.enable') == '1') != oc_wanted

      reason << 'dnsmasq update failed' unless s.route(server)
      s.reconcile_agh(agh_wanted)
      value = {
        'adguard_requested' => agh_wanted, 'openclash_requested' => oc_wanted,
        'adguard_ready' => agh_usable, 'openclash_listening' => oc_live,
        'dnsmasq_upstream' => server.empty? ? 'WAN DNS' : server,
        'adguard_upstream' => agh_usable ? upstream : [], 'degraded' => reason
      }
      if value != @last_status
        s.status(value.merge('updated_at' => Time.now.utc.to_s))
        s.log("AGH=#{agh_wanted ? 1 : 0} OC=#{oc_wanted ? 1 : 0} DNS=#{value['dnsmasq_upstream']} degraded=#{reason.length}")
        @last_status = value
      end
      value
    end
  end
end

if $PROGRAM_NAME == __FILE__
  coordinator = RouterDNS::Coordinator.new(RouterDNS::System.new)
  loop do
    begin
      coordinator.tick
    rescue StandardError => error
      RouterDNS::System.new.log("reconcile failed: #{error.class}")
    end
    sleep 2
  end
end
ROUTER_DNS_PAYLOAD_ab832053346a87daa3063d9d854f92eee8d7a0dcd905bfdd1faf130301d8edac
cat > "$stage/payload/service.init" <<'ROUTER_DNS_PAYLOAD_71149b5df78eaf5b40f19dacbb439c978106e65ca86fa1e96f38a30a4b8cf4e3'
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=98
STOP=10

start_service() {
    procd_open_instance
    procd_set_param command /usr/bin/ruby /usr/lib/router-dns-coordinator.rb
    procd_set_param respawn 3600 5 5
    procd_set_param stderr 1
    procd_set_param stdout 1
    procd_close_instance
}
ROUTER_DNS_PAYLOAD_71149b5df78eaf5b40f19dacbb439c978106e65ca86fa1e96f38a30a4b8cf4e3
cat > "$stage/SHA256SUMS" <<'ROUTER_DNS_PAYLOAD_54f2f4de42a8fd5bfed7242c656c06f41d944c52a3b2d72fb1751aa47e546b92'
b3397b067983d42372c3473e9970cce0e3e92c0985fe20f330abd9f9b2278b2d  manage.rb
a2c06a5b982ef0d7e81f08930b431e02686cba8daadaf2756d5627d957fdffdc  install.sh
85e5ccf8d18b39bf5c294028ee0ffa0947ee382c9a77d34301051b5e8f35cd42  patches.yml
ab832053346a87daa3063d9d854f92eee8d7a0dcd905bfdd1faf130301d8edac  payload/coordinator.rb
71149b5df78eaf5b40f19dacbb439c978106e65ca86fa1e96f38a30a4b8cf4e3  payload/service.init
ROUTER_DNS_PAYLOAD_54f2f4de42a8fd5bfed7242c656c06f41d944c52a3b2d72fb1751aa47e546b92
(cd "$stage" && sha256sum -c SHA256SUMS >/dev/null)
sh "$stage/install.sh" "$action"
