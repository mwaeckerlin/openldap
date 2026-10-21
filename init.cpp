/**

OpenLDAP init: shell-free entrypoint and PID 1 of the openldap container.

  1. Reads and validates the environment; a value that cannot be used stops
     the container with `invalid <VARIABLE>`.
  2. Takes the administrator password from PASSWORD, from /etc/ldap/password,
     or generates one and stores it there.
  3. Writes /etc/ldap/slapd.conf.
  4. Restores the one file /var/restore/*data.ldif, or else saves the existing
     database to /var/backups/<date>-startup-data.ldif.
  5. Starts slapd, applies INIT_SCRIPT once slapd accepts the administrator,
     passes SIGTERM and SIGINT on to slapd and ends with its exit status.

`--healthcheck` binds as the administrator on 127.0.0.1:389 and succeeds only
on the LDAP result `success`.

*/

#include <algorithm>
#include <arpa/inet.h>
#include <cerrno>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <exception>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <netinet/in.h>
#include <sstream>
#include <stdexcept>
#include <string>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <unistd.h>
#include <vector>

namespace fs = std::filesystem;

namespace {

constexpr const char *SBIN          = "/usr/sbin/";
constexpr const char *LDAPMODIFY    = "/usr/bin/ldapmodify";
constexpr const char *CONF          = "/etc/ldap/slapd.conf";
constexpr const char *TOOLS_CONF    = "/run/openldap/tools.conf";
constexpr const char *PASSWORD_FILE = "/etc/ldap/password";
constexpr const char *SECRET_FILE   = "/run/openldap/secret";
constexpr const char *DATA          = "/var/lib/ldap";
constexpr const char *RESTORE_TMP   = "/var/lib/ldap/.restore";
constexpr const char *BACKUPS       = "/var/backups";
constexpr const char *RESTORE       = "/var/restore";
constexpr const char *SCHEMA_DIR    = "/etc/openldap/schema";
constexpr const char *LDAPI         = "ldapi://%2Frun%2Fopenldap%2Fldapi";
constexpr int LDAP_PORT             = 389;

constexpr const char *DEFAULT_ACCESS_RULES = "access to * by self write by users read by anonymous auth";
constexpr const char *DEFAULT_SCHEMAS      = "cosine inetorgperson nis samba";

volatile sig_atomic_t child_pid = 0;
volatile sig_atomic_t stopping  = 0;

void
forward(int sig) {
  stopping = 1;
  if (child_pid > 0) kill(child_pid, sig);
}

std::string
env_or(const char *name, const std::string &fallback = {}) {
  const char *v = std::getenv(name);
  return (v && *v) ? std::string(v) : fallback;
}

[[noreturn]] void
invalid(const char *name, const std::string &why) {
  throw std::runtime_error(std::string("invalid ") + name + ": " + why);
}

bool
printable(const std::string &v) {
  for (unsigned char c : v)
    if (c < 0x20 || c == 0x7f) return false;
  return true;
}

bool
only(const std::string &v, const std::string &allowed) {
  return !v.empty() && v.find_first_not_of(allowed) == std::string::npos;
}

const std::string ALNUM = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
const std::string PATH_CHARS = ALNUM + "/._-";

std::vector<std::string>
split(const std::string &v) {
  std::vector<std::string> out;
  std::istringstream in(v);
  for (std::string w; in >> w;) out.push_back(w);
  return out;
}

std::string
replace_all(std::string v, const std::string &from, const std::string &to) {
  for (auto at = v.find(from); at != std::string::npos; at = v.find(from, at + to.size()))
    v.replace(at, from.size(), to);
  return v;
}

std::string
trim(const std::string &v) {
  const auto first = v.find_first_not_of(" \t\r\n");
  if (first == std::string::npos) return {};
  return v.substr(first, v.find_last_not_of(" \t\r\n") - first + 1);
}

std::string
read_file(const fs::path &p) {
  std::ifstream in(p, std::ios::binary);
  if (!in) throw std::runtime_error("cannot read " + p.string());
  std::ostringstream s;
  s << in.rdbuf();
  return s.str();
}

void
write_file(const fs::path &p, const std::string &content, mode_t mode) {
  const mode_t old = umask(077);
  std::ofstream out(p, std::ios::binary | std::ios::trunc);
  umask(old);
  if (!out) throw std::runtime_error("cannot write " + p.string());
  out << content;
  out.close();
  if (!out) throw std::runtime_error("cannot write " + p.string());
  chmod(p.c_str(), mode);
}

struct Config {
  std::string domain, basedn, admin, password, debug, access, indexes, maxsize;
  std::vector<std::string> schemas, custom_schemas;
  std::string init_script;
  bool memberof = false;
  std::string tls_cert, tls_key, tls_ca;
};

Config
read_config() {
  Config c;
  c.domain = env_or("DOMAIN");
  if (c.domain.empty())
    throw std::runtime_error("Specifying a domain is mandatory, use -e DOMAIN=example.org");
  if (!only(c.domain, ALNUM + ".-") || c.domain.front() == '.' || c.domain.back() == '.' ||
      c.domain.find("..") != std::string::npos)
    invalid("DOMAIN", "a domain name such as example.org is expected");
  c.basedn = "dc=" + replace_all(c.domain, ".", ",dc=");
  c.admin = "cn=admin," + c.basedn;

  c.password = env_or("PASSWORD");
  if (c.password.find_first_of("\r\n") != std::string::npos)
    invalid("PASSWORD", "the password must not contain a line break");

  c.debug = env_or("DEBUG", "256");
  if (!only(c.debug, ALNUM + ",-"))
    invalid("DEBUG", "a slapd debug level such as 256, stats or -1 is expected");

  c.maxsize = env_or("MAXSIZE", "10737418240");
  if (!only(c.maxsize, "0123456789") || c.maxsize.size() > 19)
    invalid("MAXSIZE", "the maximum database size in bytes is expected");

  c.access = trim(env_or("ACCESS_RULES", DEFAULT_ACCESS_RULES));
  if (!printable(c.access) || c.access.rfind("access to ", 0) != 0)
    invalid("ACCESS_RULES", "rules starting with «access to», on one line, are expected");

  c.indexes = trim(env_or("INDEXES"));
  if (!c.indexes.empty() &&
      (!only(c.indexes, ALNUM + " ,;._-") || c.indexes.rfind("index ", 0) != 0))
    invalid("INDEXES", "a list such as «index uid eq index cn eq,sub» is expected");

  const std::string memberof = env_or("MEMBEROF", "0");
  if (memberof != "0" && memberof != "1") invalid("MEMBEROF", "0 or 1 is expected");
  c.memberof = memberof == "1";

  for (const auto &name : split(env_or("SCHEMAS", DEFAULT_SCHEMAS))) {
    if (!only(name, ALNUM + "_-")) invalid("SCHEMAS", "«" + name + "» is not a schema name");
    if (name == "core") continue;
    if (!fs::is_regular_file(fs::path(SCHEMA_DIR) / (name + ".schema")))
      invalid("SCHEMAS", "the image carries no schema «" + name + "» in " + SCHEMA_DIR);
    c.schemas.push_back(name);
  }

  const std::string custom = env_or("CUSTOM_SCHEMAS");
  if (!custom.empty()) {
    if (!only(custom, PATH_CHARS) || custom.front() != '/')
      invalid("CUSTOM_SCHEMAS", "an absolute path is expected");
    if (fs::is_directory(custom)) {
      for (const auto &e : fs::recursive_directory_iterator(custom)) {
        const std::string p = e.path().string();
        if (!e.is_regular_file() || e.path().extension() != ".schema") continue;
        if (!only(p, PATH_CHARS))
          invalid("CUSTOM_SCHEMAS", "the file name «" + p + "» may only contain letters, digits and «/._-»");
        c.custom_schemas.push_back(p);
      }
      std::sort(c.custom_schemas.begin(), c.custom_schemas.end());
    } else {
      std::cerr << "**** CUSTOM_SCHEMAS: " << custom << " is no directory, no custom schema loaded" << std::endl;
    }
  }

  c.init_script = env_or("INIT_SCRIPT");
  if (!c.init_script.empty() && (!only(c.init_script, PATH_CHARS) || c.init_script.front() != '/'))
    invalid("INIT_SCRIPT", "an absolute path is expected");

  const fs::path live = fs::path("/ssl/live") / c.domain;
  const fs::path flat = "/ssl";
  if (fs::exists(live / "cert.pem") && fs::exists(live / "privkey.pem") && fs::exists(live / "chain.pem")) {
    c.tls_cert = (live / "cert.pem").string();
    c.tls_key  = (live / "privkey.pem").string();
    c.tls_ca   = (live / "chain.pem").string();
  } else if (fs::exists(flat / (c.domain + ".pem")) && fs::exists(flat / (c.domain + ".key")) &&
             fs::exists(flat / (c.domain + "-ca.crt"))) {
    c.tls_cert = (flat / (c.domain + ".pem")).string();
    c.tls_key  = (flat / (c.domain + ".key")).string();
    c.tls_ca   = (flat / (c.domain + "-ca.crt")).string();
  }
  for (const auto &f : {c.tls_cert, c.tls_key, c.tls_ca}) {
    if (f.empty()) continue;
    if (access(f.c_str(), R_OK) != 0)
      throw std::runtime_error("TLS: " + f + " exists but the user ldap (uid " + std::to_string(getuid()) +
                               ") cannot read it; give it to that uid or to the group shared-access (gid 500)");
  }
  return c;
}

std::string
stored_password() {
  if (!fs::exists(PASSWORD_FILE)) return {};
  return trim(read_file(PASSWORD_FILE));
}

std::string
generate_password() {
  std::ifstream random("/dev/urandom", std::ios::binary);
  if (!random) throw std::runtime_error("cannot read /dev/urandom");
  std::string password;
  while (password.size() < 20) {
    const unsigned char c = static_cast<unsigned char>(random.get());
    if (c < 248) password += ALNUM[c % ALNUM.size()];
  }
  return password;
}

pid_t
spawn(const std::string &path, const std::vector<std::string> &args, int out_fd = -1) {
  const pid_t pid = fork();
  if (pid < 0) throw std::runtime_error("fork failed: " + std::string(std::strerror(errno)));
  if (pid == 0) {
    signal(SIGTERM, SIG_DFL);
    signal(SIGINT, SIG_DFL);
    if (out_fd >= 0) dup2(out_fd, STDOUT_FILENO);
    std::vector<char *> argv;
    for (const auto &a : args) argv.push_back(const_cast<char *>(a.c_str()));
    argv.push_back(nullptr);
    execv(path.c_str(), argv.data());
    std::perror(path.c_str());
    _exit(127);
  }
  return pid;
}

int
wait_for(pid_t pid) {
  child_pid = pid;
  int status = 0;
  while (waitpid(pid, &status, 0) < 0)
    if (errno != EINTR) throw std::runtime_error("waitpid failed: " + std::string(std::strerror(errno)));
  child_pid = 0;
  if (stopping) std::exit(143);
  return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}

int
run(const std::string &path, const std::vector<std::string> &args) {
  return wait_for(spawn(path, args));
}

std::string
run_output(const std::string &path, const std::vector<std::string> &args) {
  int fds[2];
  if (pipe(fds) != 0) throw std::runtime_error("pipe failed");
  const pid_t pid = spawn(path, args, fds[1]);
  close(fds[1]);
  std::string out;
  char buffer[256];
  for (ssize_t n; (n = read(fds[0], buffer, sizeof buffer)) != 0;) {
    if (n < 0) {
      if (errno == EINTR) continue;
      break;
    }
    out.append(buffer, static_cast<std::size_t>(n));
  }
  close(fds[0]);
  if (wait_for(pid) != 0) throw std::runtime_error(args.front() + " failed");
  return trim(out);
}

std::string
slapd_conf(const Config &c, const std::string &rootpw, const std::string &directory, bool tls) {
  std::string conf;
  conf += "include " + std::string(SCHEMA_DIR) + "/core.schema\n";
  for (const auto &s : c.schemas) conf += "include " + std::string(SCHEMA_DIR) + "/" + s + ".schema\n";
  for (const auto &s : c.custom_schemas) conf += "include " + s + "\n";
  conf += "modulepath /usr/lib/openldap\n";
  conf += "moduleload back_mdb.so\n";
  if (c.memberof) conf += "moduleload refint.so\nmoduleload memberof.so\n";
  conf += "pidfile /run/openldap/slapd.pid\n";
  conf += "argsfile /run/openldap/slapd.args\n";
  if (tls && !c.tls_cert.empty()) {
    conf += "TLSCertificateFile " + c.tls_cert + "\n";
    conf += "TLSCertificateKeyFile " + c.tls_key + "\n";
    conf += "TLSCACertificateFile " + c.tls_ca + "\n";
    conf += "TLSProtocolMin 3.3\n";
    conf += "TLSCipherSuite HIGH:!aNULL:!MD5:!RC4\n";
  }
  conf += "database mdb\n";
  conf += "maxsize " + c.maxsize + "\n";
  conf += "suffix \"" + c.basedn + "\"\n";
  conf += "rootdn \"" + c.admin + "\"\n";
  conf += "rootpw " + rootpw + "\n";
  conf += "directory " + directory + "\n";
  conf += "index objectClass eq\n";
  if (!c.indexes.empty()) conf += replace_all(c.indexes, " index", "\nindex") + "\n";
  if (c.memberof) {
    conf += "overlay refint\n";
    conf += "refint_attributes member\n";
    conf += "refint_nothing \"" + c.admin + "\"\n";
    conf += "overlay memberof\n";
    conf += "memberof-group-oc groupOfNames\n";
    conf += "memberof-member-ad member\n";
    conf += "memberof-memberof-ad memberOf\n";
    conf += "memberof-refint true\n";
  }
  conf += replace_all(replace_all(c.access, " access to", "\naccess to"), " by", "\n\tby") + "\n";
  return conf;
}

std::string
now() {
  char buffer[32];
  const std::time_t t = std::time(nullptr);
  std::strftime(buffer, sizeof buffer, "%Y%m%d%H%M", std::localtime(&t));
  return buffer;
}

std::vector<fs::path>
restore_files() {
  std::vector<fs::path> found;
  if (!fs::is_directory(RESTORE)) return found;
  const std::string suffix = "data.ldif";
  for (const auto &e : fs::directory_iterator(RESTORE)) {
    const std::string name = e.path().filename().string();
    if (e.is_regular_file() && name.size() >= suffix.size() &&
        name.compare(name.size() - suffix.size(), suffix.size(), suffix) == 0)
      found.push_back(e.path());
  }
  return found;
}

void
restore_or_backup(const Config &c, const std::string &rootpw) {
  const std::string date = now();
  const auto files = restore_files();
  if (files.size() > 1)
    throw std::runtime_error(std::to_string(files.size()) + " files match /var/restore/*data.ldif; leave exactly the one to restore");
  if (files.size() == 1) {
    const fs::path file = files.front();
    std::cerr << "**** restoring " << file.string() << std::endl;
    fs::remove_all(RESTORE_TMP);
    fs::create_directory(RESTORE_TMP);
    chmod(RESTORE_TMP, 0700);
    write_file(TOOLS_CONF, slapd_conf(c, rootpw, RESTORE_TMP, false), 0600);
    if (run(std::string(SBIN) + "slapadd", {"slapadd", "-f", TOOLS_CONF, "-l", file.string()}) != 0) {
      fs::remove_all(RESTORE_TMP);
      throw std::runtime_error("restore of " + file.string() + " failed, the database stays as it was; correct or remove the file");
    }
    fs::remove(fs::path(DATA) / "data.mdb");
    fs::remove(fs::path(DATA) / "lock.mdb");
    fs::rename(fs::path(RESTORE_TMP) / "data.mdb", fs::path(DATA) / "data.mdb");
    fs::remove_all(RESTORE_TMP);
    const fs::path kept = fs::path(BACKUPS) / (date + "-restored-data.ldif");
    std::error_code error;
    fs::copy_file(file, kept, fs::copy_options::overwrite_existing, error);
    if (!error) fs::remove(file, error);
    if (error)
      std::cerr << "**** " << file.string() << " stays in place (" << error.message()
                << "), the next start restores it again" << std::endl;
    else
      std::cerr << "**** restored, the file is now " << kept.string() << std::endl;
  } else if (fs::exists(fs::path(DATA) / "data.mdb")) {
    const fs::path backup = fs::path(BACKUPS) / (date + "-startup-data.ldif");
    write_file(TOOLS_CONF, slapd_conf(c, rootpw, DATA, false), 0600);
    if (run(std::string(SBIN) + "slapcat", {"slapcat", "-f", TOOLS_CONF, "-l", backup.string()}) != 0)
      throw std::runtime_error("backup to " + backup.string() + " failed");
    std::cerr << "**** backup " << backup.string() << std::endl;
  }
  fs::remove(TOOLS_CONF);
}

std::string
ber_length(std::size_t n) {
  if (n < 0x80) return std::string(1, static_cast<char>(n));
  std::string bytes;
  for (; n; n >>= 8) bytes.insert(bytes.begin(), static_cast<char>(n & 0xff));
  return std::string(1, static_cast<char>(0x80 | bytes.size())) + bytes;
}

std::string
tlv(unsigned char tag, const std::string &value) {
  return std::string(1, static_cast<char>(tag)) + ber_length(value.size()) + value;
}

// reads tag and length at pos; false while the buffer holds less than the whole element
bool
read_tlv(const std::string &b, std::size_t &pos, unsigned char &tag, std::size_t &len) {
  if (pos + 2 > b.size()) return false;
  tag = static_cast<unsigned char>(b[pos++]);
  unsigned char first = static_cast<unsigned char>(b[pos++]);
  len = first;
  if (first & 0x80) {
    const std::size_t count = first & 0x7f;
    if (count == 0 || count > 4 || pos + count > b.size()) return false;
    len = 0;
    for (std::size_t i = 0; i < count; ++i) len = (len << 8) | static_cast<unsigned char>(b[pos++]);
  }
  return pos + len <= b.size();
}

// LDAP result code of a simple bind, -1 when no answer arrives
int
bind_result(const std::string &dn, const std::string &password) {
  const int s = socket(AF_INET, SOCK_STREAM, 0);
  if (s < 0) return -1;
  timeval timeout{3, 0};
  setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout);
  setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof timeout);
  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_port = htons(LDAP_PORT);
  inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);
  if (connect(s, reinterpret_cast<sockaddr *>(&addr), sizeof addr) != 0) {
    close(s);
    return -1;
  }
  const std::string request =
      tlv(0x30, tlv(0x02, std::string(1, '\x01')) +
                    tlv(0x60, tlv(0x02, std::string(1, '\x03')) + tlv(0x04, dn) + tlv(0x80, password)));
  if (send(s, request.data(), request.size(), MSG_NOSIGNAL) != static_cast<ssize_t>(request.size())) {
    close(s);
    return -1;
  }
  std::string answer;
  char buffer[512];
  int result = -1;
  for (;;) {
    std::size_t pos = 0, len = 0;
    unsigned char tag = 0;
    if (read_tlv(answer, pos, tag, len)) {
      std::size_t inner = pos;
      if (tag == 0x30 && read_tlv(answer, inner, tag, len) && tag == 0x02) {
        inner += len;
        if (read_tlv(answer, inner, tag, len) && tag == 0x61 && read_tlv(answer, inner, tag, len) &&
            tag == 0x0a && len == 1)
          result = static_cast<unsigned char>(answer[inner]);
      }
      break;
    }
    const ssize_t n = recv(s, buffer, sizeof buffer, 0);
    if (n <= 0) break;
    answer.append(buffer, static_cast<std::size_t>(n));
  }
  close(s);
  return result;
}

int
healthcheck(const Config &c) {
  const std::string password = c.password.empty() ? stored_password() : c.password;
  if (password.empty()) {
    std::cerr << "health check: neither PASSWORD nor " << PASSWORD_FILE << " gives the administrator password" << std::endl;
    return 1;
  }
  const int result = bind_result(c.admin, password);
  if (result == 0) return 0;
  std::cerr << "health check: bind as " << c.admin << " on port " << LDAP_PORT
            << (result < 0 ? " got no answer" : " answered with LDAP result " + std::to_string(result)) << std::endl;
  return 1;
}

} // namespace

int main(int argc, char *argv[]) try {
  const Config config = read_config();
  if (argc > 1 && std::string(argv[1]) == "--healthcheck") return healthcheck(config);

  struct sigaction action{};
  action.sa_handler = forward;
  sigemptyset(&action.sa_mask);
  for (int sig : {SIGTERM, SIGINT}) sigaction(sig, &action, nullptr);

  std::string password = config.password;
  if (password.empty()) password = stored_password();
  if (password.empty()) {
    password = generate_password();
    write_file(PASSWORD_FILE, password + "\n", 0600);
    std::cout << "password: " << password << std::endl;
  }
  write_file(SECRET_FILE, password, 0600);
  const std::string rootpw = run_output(std::string(SBIN) + "slappasswd",
                                        {"slappasswd", "-h", "{SSHA}", "-T", SECRET_FILE});

  write_file(CONF, slapd_conf(config, rootpw, DATA, true), 0600);
  restore_or_backup(config, rootpw);

  std::string listen = std::string("ldap:/// ") + LDAPI;
  if (!config.tls_cert.empty()) listen += " ldaps:///";
  std::cerr << "**** starting slapd for " << config.basedn << " on " << listen << std::endl;
  const pid_t slapd = spawn(std::string(SBIN) + "slapd", {"slapd", "-d", config.debug, "-h", listen, "-f", CONF});
  child_pid = slapd;

  int status = 0;
  bool ended = false;
  if (!config.init_script.empty()) {
    if (!fs::is_regular_file(config.init_script)) {
      std::cerr << "**** INIT_SCRIPT: " << config.init_script << " does not exist, nothing applied" << std::endl;
    } else {
      while (!stopping && bind_result(config.admin, password) != 0) {
        const pid_t done = waitpid(slapd, &status, WNOHANG);
        if (done == slapd) {
          ended = true;
          break;
        }
        sleep(1);
      }
      if (!ended && !stopping) {
        std::cerr << "**** applying INIT_SCRIPT " << config.init_script << std::endl;
        const pid_t modify = spawn(LDAPMODIFY, {"ldapmodify", "-a", "-c", "-x", "-H", "ldap://127.0.0.1:389",
                                                "-D", config.admin, "-y", SECRET_FILE, "-f", config.init_script});
        int modify_status = 0;
        while (waitpid(modify, &modify_status, 0) < 0 && errno == EINTR) {}
        const int rc = WIFEXITED(modify_status) ? WEXITSTATUS(modify_status) : 128 + WTERMSIG(modify_status);
        if (rc != 0)
          std::cerr << "**** INIT_SCRIPT ended with exit status " << rc
                    << "; every entry that could be added or changed is applied, the errors above name the others" << std::endl;
      }
    }
  }

  while (!ended) {
    const pid_t pid = waitpid(-1, &status, 0);
    if (pid == slapd) ended = true;
    else if (pid < 0 && errno == ECHILD) break;
  }
  return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
} catch (const std::exception &e) {
  std::cerr << "**** ERROR: " << e.what() << std::endl;
  return 1;
} catch (...) {
  std::cerr << "**** ERROR: unknown" << std::endl;
  return 1;
}
