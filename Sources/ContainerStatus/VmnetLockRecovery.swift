import Foundation
import CryptoKit

/// Diagnostico somente-leitura; a mudanca exige uma nova acao elevada.
enum VmnetLockRecovery {
    struct Snapshot: Equatable, Sendable {
        let configurationDirectory: String
        let memberName: String
        let pid: pid_t
        let sha256: String
        let directoryNumber: UInt64
        let memberNumber: UInt64
        let configurationNumber: UInt64
    }

    enum Diagnosis: Equatable, Sendable {
        case absent
        case eligible(Snapshot)
        case unavailable(String)
    }

    static func inspect(configurationDirectory: String = "/Library/Preferences/VMware Fusion",
                        ownerUID: uid_t = 0,
                        processExists: (pid_t) -> Bool? = { pid in
                            if kill(pid, 0) == 0 { return true }
                            return errno == ESRCH ? false : nil
                        }) -> Diagnosis {
        let base = URL(fileURLWithPath: configurationDirectory).standardizedFileURL
        guard base.resolvingSymlinksInPath().path == base.path else {
            return .unavailable("Caminho da configuracao contem symlink")
        }
        if ownerUID == 0 {
            var ancestor = base.deletingLastPathComponent()
            while true {
                var metadata = stat()
                guard lstat(ancestor.path, &metadata) == 0, metadata.st_uid == 0,
                      metadata.st_mode & S_IFMT == S_IFDIR,
                      metadata.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
                    return .unavailable("Ancestral da configuracao nao e confiavel")
                }
                if ancestor.path == "/" { break }
                ancestor.deleteLastPathComponent()
            }
        }
        let lock = base.appendingPathComponent("networking.lck")
        var directory = stat()
        guard lstat(lock.path, &directory) == 0 else {
            return errno == ENOENT ? .absent : .unavailable("Nao foi possivel consultar o lock")
        }
        var filesystem = statfs()
        guard statfs(base.path, &filesystem) == 0, filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else {
            return .unavailable("Configuracao nao esta em um disco local verificavel")
        }
        let configuration = base.appendingPathComponent("networking")
        var configurationMetadata = stat()
        var baseMetadata = stat()
        guard lstat(base.path, &baseMetadata) == 0,
              baseMetadata.st_mode & S_IFMT == S_IFDIR, baseMetadata.st_uid == ownerUID,
              baseMetadata.st_mode & (S_IWGRP | S_IWOTH) == 0,
              lstat(configuration.path, &configurationMetadata) == 0,
              configurationMetadata.st_mode & S_IFMT == S_IFREG,
              configurationMetadata.st_uid == ownerUID,
              configurationMetadata.st_mode & (S_IWGRP | S_IWOTH) == 0,
              directory.st_mode & S_IFMT == S_IFDIR, directory.st_uid == ownerUID else {
            return .unavailable("Dono, tipo ou permissoes da configuracao nao conferem")
        }
        do {
            let members = try FileManager.default.contentsOfDirectory(atPath: lock.path)
            guard members.count == 1, let name = members.first,
                  name.range(of: #"^M[0-9]+\.lck$"#, options: .regularExpression) != nil else {
                return .unavailable("Lock possui membros desconhecidos ou concorrentes")
            }
            let member = lock.appendingPathComponent(name)
            let descriptor = open(member.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else { return .unavailable("Nao foi possivel abrir o membro do lock") }
            defer {
                if close(descriptor) != 0 { NSLog("vmnet: falha ao fechar lock: %s", strerror(errno)) }
            }
            var before = stat()
            guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
                  before.st_uid == ownerUID, before.st_mode & (S_IWGRP | S_IWOTH) == 0,
                  before.st_size == 512 else {
                return .unavailable("Membro do lock nao e um arquivo VMware confiavel")
            }
            var bytes = [UInt8](repeating: 0, count: 512)
            guard read(descriptor, &bytes, 512) == 512 else {
                return .unavailable("Leitura incompleta do lock")
            }
            let header = bytes.prefix { $0 != 0 }
            guard header.count < bytes.count,
                  bytes.dropFirst(header.count).allSatisfy({ $0 == 0 }),
                  header.allSatisfy({ $0 >= 32 && $0 <= 126 }),
                  let text = String(bytes: header, encoding: .utf8) else {
                return .unavailable("Formato do lock nao reconhecido")
            }
            let fields = text.split(separator: " ")
            guard fields.count == 6,
                  fields[0].range(of: #"^uuid=(?:[0-9A-Fa-f]{2}-){15}[0-9A-Fa-f]{2}$"#,
                                  options: .regularExpression) != nil,
                  fields[1].range(of: #"^[1-9][0-9]*-[1-9][0-9]*$"#, options: .regularExpression) != nil,
                  fields[2] == "1", fields[3] == "X",
                  fields[5].range(of: #"^lc=[0-9]+$"#, options: .regularExpression) != nil else {
                return .unavailable("Formato do lock nao reconhecido")
            }
            let execution = fields[1].split(separator: "-")
            guard let pid = pid_t(execution[0]), pid > 0, execution[1] == fields[4] else {
                return .unavailable("Identificador de execucao do lock invalido")
            }
            guard let exists = processExists(pid) else {
                return .unavailable("Nao foi possivel confirmar se o processo do lock terminou")
            }
            guard !exists else { return .unavailable("Processo do lock ainda esta ativo") }
            var after = stat()
            var currentDirectory = stat()
            var currentMember = stat()
            guard fstat(descriptor, &after) == 0, lstat(lock.path, &currentDirectory) == 0,
                  lstat(member.path, &currentMember) == 0,
                  before.st_ino == currentMember.st_ino, before.st_dev == currentMember.st_dev,
                  before.st_size == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
                  before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
                  directory.st_ino == currentDirectory.st_ino,
                  directory.st_mtimespec.tv_sec == currentDirectory.st_mtimespec.tv_sec,
                  directory.st_mtimespec.tv_nsec == currentDirectory.st_mtimespec.tv_nsec,
                  try FileManager.default.contentsOfDirectory(atPath: lock.path) == members else {
                return .unavailable("Lock mudou durante a verificacao; tente diagnosticar novamente")
            }
            let digest = SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
            return .eligible(Snapshot(configurationDirectory: base.path, memberName: name, pid: pid,
                                      sha256: digest, directoryNumber: UInt64(directory.st_ino),
                                      memberNumber: UInt64(before.st_ino),
                                      configurationNumber: UInt64(configurationMetadata.st_ino)))
        } catch {
            return .unavailable("Falha ao consultar lock: \(error.localizedDescription)")
        }
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Abre sem seguir symlink nem esperar FIFO e verifica o mesmo descritor.
    static func memberVerificationShell(path: String, inode: UInt64, sha256: String,
                                        ownerUID: uid_t = 0) -> String {
        let program = #"""
        BEGIN { @INC = grep { m{^/System/Library/Perl/} } @INC; }
        use Fcntl qw(:DEFAULT :mode);
        use Digest::SHA ();
        my ($path, $inode, $expected, $owner) = @ARGV;
        sysopen(my $file, $path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW) or die "abertura segura do lock falhou\n";
        my @before = stat($file);
        @before && S_ISREG($before[2]) && $before[1] == $inode && $before[4] == $owner &&
            !($before[2] & 0022) && $before[7] == 512 or die "metadados do lock mudaram\n";
        my $bytes = "";
        my $length = sysread($file, $bytes, 513);
        defined($length) && $length == 512 or die "leitura incompleta do lock\n";
        my @after = stat($file);
        my @current = lstat($path);
        @after && @current && S_ISREG($current[2]) && S_ISREG($after[2]) &&
            $after[0] == $before[0] && $after[1] == $before[1] &&
            $after[4] == $owner && !($after[2] & 0022) && $after[7] == 512 &&
            $current[0] == $before[0] && $current[1] == $before[1] &&
            $current[4] == $owner && !($current[2] & 0022) && $current[7] == 512 &&
            Digest::SHA::sha256_hex($bytes) eq $expected or die "lock mudou durante a leitura\n";
        close($file) or die "falha ao fechar lock\n";
        """#
        return "/usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C /usr/bin/perl -e "
            + quote(program) + " " + quote(path) + " \(inode) " + quote(sha256) + " \(ownerUID)"
    }

    /// Exit 1 so significa ausencia de detentores quando nao ha saida ou erro.
    static func lsofGuardShell(command: String = "/usr/sbin/lsof") -> String {
        """
        if holders=$(\(quote(command)) -t "$base/networking" "$member" 2>&1); then
          fail 'configuracao ou lock em uso'
        else
          code=$?
          [ "$code" = 1 ] && [ -z "$holders" ] || fail "nao foi possivel excluir detentor ativo: $holders"
        fi
        """
    }

    /// Revalida tudo como root. Nao apaga arquivos nem executa start/stop.
    static func recoveryShell(snapshot: Snapshot) -> String {
        return """
        set -eu
        export LC_ALL=C PATH=/usr/bin:/bin:/usr/sbin:/sbin
        fail() { echo "vmnet recovery: $1" >&2; exit 1; }
        [ "$(/usr/bin/id -u)" = 0 ] || fail 'recuperacao exige administrador'
        base=\(quote(snapshot.configurationDirectory))
        [ "$base" = '/Library/Preferences/VMware Fusion' ] || fail 'caminho fora da configuracao VMware'
        lock="$base/networking.lck"
        member="$lock"/\(quote(snapshot.memberName))
        validate_lock() {
          parent="$base"
          while :; do
            [ -d "$parent" ] && [ ! -L "$parent" ] && [ "$(/usr/bin/find "$parent" -maxdepth 0 -user 0 ! -perm -020 ! -perm -002 | /usr/bin/wc -l | /usr/bin/tr -d ' ')" = 1 ] || fail 'ancestral da configuracao nao e confiavel'
            [ "$parent" != / ] || break
            parent=$(/usr/bin/dirname "$parent")
          done
          [ -d "$base" ] && [ ! -L "$base" ] && [ -f "$base/networking" ] && [ ! -L "$base/networking" ] || fail 'configuracao insegura'
          [ -d "$lock" ] && [ ! -L "$lock" ] && [ -f "$member" ] && [ ! -L "$member" ] || fail 'lock mudou ou contem symlink'
          [ "$(/usr/bin/stat -f %u "$lock")" = 0 ] && [ "$(/usr/bin/stat -f %u "$member")" = 0 ] || fail 'lock nao pertence ao root'
          [ "$(/usr/bin/find "$base" "$base/networking" "$member" -maxdepth 0 -user 0 ! -perm -020 ! -perm -002 | /usr/bin/wc -l | /usr/bin/tr -d ' ')" = 3 ] || fail 'configuracao gravavel ou dono invalido'
          [ "$(/bin/ls -A "$lock")" = \(quote(snapshot.memberName)) ] || fail 'membros do lock mudaram'
          [ "$(/usr/bin/stat -f %i "$lock")" = \(snapshot.directoryNumber) ] && [ "$(/usr/bin/stat -f %i "$member")" = \(snapshot.memberNumber) ] && [ "$(/usr/bin/stat -f %i "$base/networking")" = \(snapshot.configurationNumber) ] || fail 'arquivo do lock ou configuracao foi trocado'
          \(memberVerificationShell(path: snapshot.configurationDirectory + "/networking.lck/" + snapshot.memberName,
                                    inode: snapshot.memberNumber, sha256: snapshot.sha256)) || fail 'membro do lock mudou ou nao pode ser verificado'
          if reason=$(/bin/kill -0 \(snapshot.pid) 2>&1); then fail 'processo do lock esta ativo'; else
            case "$reason" in *'No such process'*) ;; *) fail 'estado do processo do lock desconhecido' ;; esac
          fi
        }
        check_processes() {
          for name in vmware-vmx vmnet-cli; do
            if /usr/bin/pgrep -x "$name" >/dev/null; then fail "processo ativo: $name"; else
              code=$?; [ "$code" = 1 ] || fail 'consulta de processos falhou'
            fi
          done
        }
        validate_lock
        check_processes
        device=$(/bin/df -P "$base" | /usr/bin/awk 'NR == 2 { print $1 }')
        case "$device" in /dev/*) ;; *) fail 'configuracao nao esta em disco local' ;; esac
        \(lsofGuardShell())
        stamp=$(/bin/date +%Y%m%d-%H%M%S)-$$
        backup="$base/networking.before-recovery-$stamp"
        orphan="$base/networking.lck.orphan-$stamp"
        [ ! -e "$backup" ] && [ ! -e "$orphan" ] || fail 'backup ja existe'
        /bin/cp -p "$base/networking" "$backup"
        /usr/bin/cmp -s "$base/networking" "$backup" || fail 'backup nao confere'
        validate_lock
        check_processes
        /bin/mv "$lock" "$orphan"
        echo "Configuracao preservada em $backup"
        echo "Lock orfao preservado em $orphan"
        """
    }
}
