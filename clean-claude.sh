#!/bin/bash
# macOS / Bash 3.2. Deliberately no recursive search outside the allowlist.

cc_usage() {
    cat <<'EOF'
Очистка локальных данных Claude Code и Claude Desktop на macOS.

  ./clean-claude.sh                        Показать список и запросить DELETE
  ./clean-claude.sh --apply                То же, что обычный запуск
  ./clean-claude.sh --scope code|desktop    Выбрать приложение (по умолчанию all)
  ./clean-claude.sh --keep-keychain         Сохранить записи авторизации
  ./clean-claude.sh --dry-run              Только список, без запроса и удаления

Удаляются история, память сессий, кэши, журналы, локальная авторизация
и персональные настройки из перечисленных в скрипте служебных путей.
Исходники, worktree, инструкции, skills, hooks, plugins, приложения,
данные браузеров и системные файлы не входят в список удаления.
Неизвестные пути и подозрительное содержимое сохраняются и выводятся.

Закройте Claude, его фоновые сессии и IDE с расширением Claude Code.
Запускайте от своего пользователя, без sudo. Удаление необратимо.
Удаление всегда требует ввода DELETE в терминале. Другой ответ отменяет его.
Облачная история и резервные копии этим скриптом не очищаются.
Коды завершения: 0 — план/очистка завершены; 1 — есть пропуски или ошибки;
2 — неверный запуск; 3 — очистка заблокирована работающим Claude.
EOF
}

cc_error() { printf 'ОШИБКА: %s\n' "$*" >&2; }
cc_exists() { [[ -e "$1" || -L "$1" ]]; }
cc_preserve() {
    printf 'СОХРАНИТЬ %q — %s\n' "$1" "$2"
    CC_PARTIAL=1
}

cc_platform() {
    [[ $(/usr/bin/uname -s) == Darwin ]] || {
        cc_error 'Поддерживается только macOS.'; return 2;
    }
    [[ $EUID -ne 0 && -z ${SUDO_USER:-} ]] || {
        cc_error 'Запустите без sudo, от владельца данных Claude.'; return 2;
    }
    CC_UID=$(/usr/bin/id -u) || return 2
    CC_USER=$(/usr/bin/id -un) || return 2
    # Get the account home from macOS, not from an overridable HOME variable.
    local record line account_uid=''
    record=$(/usr/bin/dscacheutil -q user -a uid "$CC_UID") || {
        cc_error 'Не удалось определить домашнюю папку через macOS.'; return 2;
    }
    while IFS= read -r line; do
        case "$line" in
            'uid: '*) account_uid=${line#uid: } ;;
            'dir: '*)
                [[ -z $CC_HOME ]] || { cc_error 'Неоднозначная домашняя папка.'; return 2; }
                CC_HOME=${line#dir: } ;;
        esac
    done <<< "$record"
    [[ $CC_HOME == /* && $account_uid == "$CC_UID" ]] || {
        cc_error 'В macOS нет корректной записи домашней папки.'; return 2;
    }
    CC_HOME=$(cd -P -- "$CC_HOME" && pwd -P) || return 2
    case "$CC_HOME" in
        /|/Users|/System|/Library|/Applications|/private|/private/tmp|/Volumes)
            cc_error 'Недопустимая домашняя папка.'; return 2 ;;
    esac
    [[ $(/usr/bin/stat -f '%u' "$CC_HOME") == "$CC_UID" ]] || return 2
    CC_TEMP=$(/usr/bin/getconf DARWIN_USER_TEMP_DIR) || return 2
    CC_TEMP=$(cd -P -- "$CC_TEMP" && pwd -P) || return 2
    CC_SYSTEM_TEMP=/private/tmp
}

# Reject symlinks in *every* existing path component, even if they point inward.
# Never resolve a candidate symlink and then delete its destination.
cc_check_path() {
    local path=$1 cursor=/ component rest
    CC_REASON=''
    case "$path" in
        /*) ;;
        *) CC_REASON='не абсолютный путь'; return 1 ;;
    esac
    rest=${path#/}
    while [[ -n $rest ]]; do
        component=${rest%%/*}
        if [[ $rest == */* ]]; then rest=${rest#*/}; else rest=''; fi
        case "$component" in
            ''|.|..) CC_REASON='неоднозначный путь'; return 1 ;;
        esac
        cursor=${cursor%/}/$component
        if [[ -L $cursor ]]; then CC_REASON='символическая ссылка в пути'; return 1; fi
        # A repository can itself be placed in a nominal Claude data directory.
        if [[ -d $cursor ]] && { cc_exists "$cursor/.git" || cc_exists "$cursor/.hg" || cc_exists "$cursor/.svn"; }; then
            CC_REASON='путь находится внутри репозитория'; return 1
        fi
    done
}

cc_stat_signature() {
    # Device/inode/type/owner/link count. No content reads, no symlink following.
    /usr/bin/stat -f '%d:%i:%HT:%u:%l' "$1"
}

# Refuse an entire candidate tree if it may contain user code or another tree.
# This is an additional guard, not a claim that extensions identify every source.
cc_inspect() {
    local path=$1 kind=$2 policy=$3 suspicious rc
    cc_check_path "$path" || return 1
    [[ $(/usr/bin/stat -f '%u' "$path") == "$CC_UID" ]] || {
        CC_REASON='другой владелец или ошибка stat'; return 1;
    }
    if [[ $kind == file ]]; then
        [[ -f $path && $(/usr/bin/stat -f '%l' "$path") == 1 ]] || {
            CC_REASON='ожидался обычный файл без жёстких ссылок'; return 1;
        }
        return 0
    fi
    [[ -d $path && -r $path && -x $path ]] || {
        CC_REASON='ожидалась доступная папка'; return 1;
    }
    [[ $(/usr/bin/stat -f '%d' "$path") == "$(/usr/bin/stat -f '%d' "${path%/*}")" ]] || {
        CC_REASON='папка является точкой монтирования'; return 1;
    }
    local -a extra
    extra=()
    # Generated snapshots may retain the executable bit of the original file.
    if [[ $policy == snapshots ]]; then
        extra=(-o \( \( -iname '*.sh' -o -iname '*.bash' -o -iname '*.zsh' -o -iname '*.fish'
            -o \( -type f -perm +111 \) \) ! -name 'snapshot-*.sh' ! -name 'snapshot-*.zsh' \))
    elif [[ $policy == history ]]; then
        extra=(-o -iname '*.sh' -o -iname '*.bash' -o -iname '*.zsh' -o -iname '*.fish'
            -o \( -type f -perm +111 ! -name '*@v[0-9]*' \))
    else
        extra=(-o -iname '*.sh' -o -iname '*.bash' -o -iname '*.zsh' -o -iname '*.fish'
            -o \( -type f -perm +111 \))
    fi
    suspicious=$(/usr/bin/find -P "$path" -xdev \
        \( -type l -o ! -user "$CC_UID" -o \( -type f -links +1 \) \
        -o \( ! -type f ! -type d \) \
        -o -name .git -o -name .hg -o -name .svn \
        -o -iname worktrees -o -iname worktree -o -name .claude \
        -o -iname CLAUDE.md -o -iname AGENTS.md -o -iname SKILL.md \
        -o -iname package.json -o -iname pyproject.toml -o -iname Cargo.toml \
        -o -iname go.mod -o -iname Makefile -o -iname CMakeLists.txt \
        -o -iname '*.py' -o -iname '*.pyw' -o -iname '*.js' -o -iname '*.mjs' \
        -o -iname '*.cjs' -o -iname '*.jsx' -o -iname '*.ts' -o -iname '*.tsx' \
        -o -iname '*.c' -o -iname '*.cc' -o -iname '*.cpp' -o -iname '*.h' \
        -o -iname '*.hpp' -o -iname '*.rs' -o -iname '*.go' -o -iname '*.java' \
        -o -iname '*.kt' -o -iname '*.swift' -o -iname '*.m' -o -iname '*.mm' \
        -o -iname '*.rb' -o -iname '*.php' -o -iname '*.pl' -o -iname '*.lua' \
        -o -iname '*.cs' -o -iname '*.fs' -o -iname '*.scala' -o -iname '*.vue' \
        -o -iname '*.svelte' -o -iname '*.sql' -o -iname '*.r' -o -iname '*.Rmd' \
        -o -iname '*.ps1' -o -iname '*.psm1' -o -iname '*.bat' -o -iname '*.cmd' \
        -o -iname '*.dart' -o -iname '*.ex' -o -iname '*.exs' -o -iname '*.erl' \
        -o -iname '*.hs' -o -iname '*.clj' -o -iname '*.cljs' -o -iname '*.zig' \
        -o -iname '*.html' -o -iname '*.css' -o -iname '*.scss' -o -iname '*.sass' \
        -o -iname '*.yaml' -o -iname '*.yml' -o -iname '*.toml' -o -iname '*.tf' \
        -o -iname '*.proto' -o -iname '*.graphql' -o -iname Dockerfile \
        -o -iname '*.ipynb' -o -iname '*.dylib' -o -iname '*.so' -o -iname '*.app' \
        -o -iname '*.sparsebundle' -o -iname '*.sparseimage' -o -iname '*.qcow2' \
        "${extra[@]}" \) -print -quit 2>&1)
    rc=$?
    if [[ $rc -ne 0 ]]; then
        CC_REASON='ошибка чтения содержимого папки'
        return 1
    fi
    if [[ -n $suspicious ]]; then
        printf -v CC_REASON 'защищённое содержимое внутри папки: %q' "$suspicious"
        return 1
    fi
    return 0
}

cc_add() {
    local path=$1 kind=$2 policy=${3:-data} count signature
    # Only calls from the literal manifest below can create deletion candidates.
    CC_KNOWN[${#CC_KNOWN[@]}]=$path
    cc_exists "$path" || return 0
    if ! cc_inspect "$path" "$kind" "$policy"; then
        cc_preserve "$path" "$CC_REASON"; return 0
    fi
    signature=$(cc_stat_signature "$path") || { cc_preserve "$path" 'ошибка stat'; return 0; }
    count=${#CC_PATHS[@]}
    CC_PATHS[count]=$path
    CC_KINDS[count]=$kind
    CC_POLICIES[count]=$policy
    CC_SIGNATURES[count]=$signature
    printf 'УДАЛИТЬ   %q\n' "$path"
}

cc_known() {
    local known
    for known in "${CC_KNOWN[@]}"; do [[ $known == "$1" ]] && return 0; done
    return 1
}

cc_report_remaining() {
    local dir=$1 path
    [[ -d $dir ]] || return 0
    if ! cc_check_path "$dir"; then cc_preserve "$dir" "$CC_REASON"; return 0; fi
    [[ -r $dir && -x $dir ]] || { cc_preserve "$dir" 'нельзя прочитать папку'; return 0; }
    for path in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
        cc_exists "$path" || continue
        cc_known "$path" || cc_preserve "$path" 'не входит в список служебных данных'
    done
}

cc_code_manifest() {
    local name path base=$CC_HOME/.claude
    for name in projects history.jsonl; do
        if [[ $name == history.jsonl ]]; then cc_add "$base/$name" file; else cc_add "$base/$name" tree; fi
    done
    for name in debug logs telemetry statsig cache paste-cache image-cache \
        plans todos tasks sessions session-env ide backups state downloads \
        feedback feedback-bundles usage-data agent-memory agent-memory-local \
        jobs daemon; do
        cc_add "$base/$name" tree
    done
    cc_add "$base/file-history" tree history
    cc_add "$base/shell-snapshots" tree snapshots
    for name in .credentials.json .device-keys settings.json settings.local.json \
        stats-cache.json mcp-needs-auth-cache.json remote-settings.json \
        policy-limits.json policy-limits.json.stamp.json .last-cleanup \
        .last-update-result.json .oauth_refresh.lock .oauth_refresh.lock.owner; do
        cc_add "$base/$name" file
    done
    cc_add "$CC_HOME/.claude.json" file
    cc_add "$CC_HOME/.claude.json.backup" file
    for path in "$CC_HOME"/.claude.json.backup.* "$CC_HOME"/.claude.json.corrupted.*; do
        cc_exists "$path" || continue
        if [[ ${path##*.} =~ ^[0-9]+$ ]]; then
            cc_add "$path" file
        else
            cc_preserve "$path" 'неизвестный формат имени резервной копии'
        fi
    done
    cc_add "$CC_HOME/Library/Caches/claude-cli-nodejs" tree
    cc_add "$CC_HOME/.cache/claude" tree
    cc_add "$CC_HOME/.local/state/claude" tree
    cc_add "$CC_SYSTEM_TEMP/claude-$CC_UID" tree
    if [[ -n $CC_TEMP && $CC_TEMP != "$CC_SYSTEM_TEMP" ]]; then
        cc_add "$CC_TEMP/claude-$CC_UID" tree
    fi
    cc_report_remaining "$base"
    # An environment variable is not authority to remove an arbitrary directory.
    if [[ -n ${CLAUDE_CONFIG_DIR:-} && ${CLAUDE_CONFIG_DIR%/} != "$base" ]]; then
        cc_preserve "$CLAUDE_CONFIG_DIR" 'нестандартный CLAUDE_CONFIG_DIR; автоматическое удаление отключено'
    fi
    if [[ -n ${CLAUDE_CODE_TMPDIR:-} ]]; then
        cc_preserve "$CLAUDE_CODE_TMPDIR" 'нестандартный CLAUDE_CODE_TMPDIR; требуется отдельная проверка'
    fi
    if [[ -n ${XDG_CACHE_HOME:-} && ${XDG_CACHE_HOME%/} != "$CC_HOME/.cache" ]]; then
        cc_preserve "$XDG_CACHE_HOME" 'нестандартный XDG_CACHE_HOME; общий каталог не очищается'
    fi
}

cc_desktop_manifest() {
    local base="$CC_HOME/Library/Application Support/Claude" name
    local bundle=com.anthropic.claudefordesktop
    for name in Cache 'Code Cache' GPUCache DawnCache DawnGraphiteCache DawnWebGPUCache \
        GrShaderCache ShaderCache Crashpad 'Local Storage' 'Session Storage' \
        IndexedDB blob_storage databases 'Service Worker' 'Shared Dictionary' \
        WebStorage Network Partitions sentry claude-code-sessions; do
        cc_add "$base/$name" tree
    done
    for name in Cookies Cookies-journal DIPS DIPS-wal DIPS-shm \
        'Local State' Preferences 'Secure Preferences' 'Network Persistent State' \
        TransportSecurity 'Trust Tokens' 'Trust Tokens-journal' \
        InterestGroups InterestGroups-wal InterestGroups-shm SharedStorage \
        SharedStorage-wal SharedStorage-shm SharedStorage-journal \
        QuotaManager QuotaManager-journal Reporting\ and\ NEL \
        config.json claude_desktop_config.json window-state.json ant-did \
        buddy-tokens.json cowork-enabled-cli-ops.json extensions-blocklist.json fcache; do
        cc_add "$base/$name" file
    done
    for name in "Caches/$bundle" "Caches/$bundle.ShipIt" "Logs/Claude" \
        "HTTPStorages/$bundle" "WebKit/$bundle" "Saved Application State/$bundle.savedState"; do
        cc_add "$CC_HOME/Library/$name" tree
    done
    cc_add "$CC_HOME/Library/Preferences/$bundle.plist" file
    cc_add "$CC_HOME/Library/HTTPStorages/$bundle.binarycookies" file
    # Cowork VM images and sessions can hold the only copy of a user's work.
    # Never delete them or git-worktrees.json automatically.
    cc_report_remaining "$base"
}

cc_process_snapshot() { /bin/ps -ww -axo uid=,pid=,comm=; }
cc_process_args() { /bin/ps -ww -p "$1" -o args=; }

cc_check_processes() {
    local snapshot uid pid executable name args found=0
    snapshot=$(cc_process_snapshot) || { cc_error 'Не удалось проверить процессы.'; return 3; }
    while read -r uid pid executable; do
        [[ $uid == "$CC_UID" ]] || continue
        name=${executable##*/}
        case "$name" in
            claude|Claude|claude-native|claude-code|'Claude Helper'*)
                printf 'Работает Claude, PID %s\n' "$pid" >&2; found=1 ;;
            node|bun)
                args=$(cc_process_args "$pid") || {
                    # A process may exit between the two ps calls.
                    continue
                }
                case "$args" in
                    *'@anthropic-ai/claude-code/'*|*'/claude-code/cli.js'*)
                        printf 'Работает Claude Code, PID %s\n' "$pid" >&2; found=1 ;;
                esac ;;
            *)
                case "$executable" in
                    *'/Claude.app/Contents/'*|*'/.local/share/claude/versions/'*)
                        printf 'Работает компонент Claude, PID %s\n' "$pid" >&2; found=1 ;;
                esac ;;
        esac
    done <<< "$snapshot"
    [[ $found == 0 ]] || {
        cc_error 'Закройте Claude и IDE с Claude Code, затем повторите запуск. Процессы не завершались.'
        return 3
    }
}

cc_security() { /usr/bin/security "$@"; }

cc_keychain_item() {
    local service=$1 account=$2 rc
    if [[ $CC_APPLY == 0 ]]; then
        printf 'KEYCHAIN  service=%q account=%q (если запись существует)\n' "$service" "$account"
        return 0
    fi
    cc_security find-generic-password -s "$service" -a "$account" "$CC_KEYCHAIN" >/dev/null 2>&1
    rc=$?
    [[ $rc == 44 ]] && return 0 # errSecItemNotFound; other errors are NOT absence.
    if [[ $rc != 0 ]]; then
        cc_preserve "Keychain: $service / $account" "ошибка чтения метаданных ($rc)"; return 0
    fi
    if ! cc_security delete-generic-password -s "$service" -a "$account" "$CC_KEYCHAIN" >/dev/null 2>&1; then
        cc_preserve "Keychain: $service / $account" 'ошибка удаления'; return 0
    fi
    cc_security find-generic-password -s "$service" -a "$account" "$CC_KEYCHAIN" >/dev/null 2>&1
    rc=$?
    if [[ $rc == 44 ]]; then
        printf 'УДАЛЕНО   Keychain: %q / %q\n' "$service" "$account"
    else
        cc_preserve "Keychain: $service / $account" 'не удалось подтвердить отсутствие записи'
    fi
}

cc_keychain() {
    [[ $CC_KEEP_KEYCHAIN == 0 ]] || return 0
    if [[ $CC_APPLY == 1 ]]; then
        CC_KEYCHAIN="$CC_HOME/Library/Keychains/login.keychain-db"
        if ! cc_exists "$CC_KEYCHAIN"; then CC_KEYCHAIN="$CC_HOME/Library/Keychains/login.keychain"; fi
        if ! cc_exists "$CC_KEYCHAIN"; then
            cc_preserve 'Keychain' 'стандартная связка login не найдена'; return 0
        fi
        if ! cc_inspect "$CC_KEYCHAIN" file data; then
            cc_preserve "$CC_KEYCHAIN" "$CC_REASON"; return 0
        fi
    fi
    if [[ $CC_SCOPE != desktop ]]; then
        cc_keychain_item 'Claude Code-credentials' "$CC_USER"
        cc_keychain_item 'Claude Code' "$CC_USER"
        cc_keychain_item 'Claude Code-device-keys' "$CC_USER"
    fi
    if [[ $CC_SCOPE != code ]]; then cc_keychain_item 'Claude Safe Storage' 'Claude Key'; fi
}

cc_delete_plan() {
    local i path signature rc
    for ((i=0; i<${#CC_PATHS[@]}; i++)); do
        path=${CC_PATHS[i]}
        cc_exists "$path" || continue
        # Revalidate after the confirmation prompt, before each deletion.
        if ! cc_inspect "$path" "${CC_KINDS[i]}" "${CC_POLICIES[i]}"; then
            cc_preserve "$path" "$CC_REASON"; continue
        fi
        signature=$(cc_stat_signature "$path") || signature=''
        if [[ $signature != "${CC_SIGNATURES[i]}" ]]; then
            cc_preserve "$path" 'объект изменился после построения плана'; continue
        fi
        if [[ ${CC_KINDS[i]} == file ]]; then
            /bin/rm -f -- "$path"
            rc=$?
        else
            # No rm -rf: do not descend into mounts, do not follow links,
            # and remove directories only when empty. Failures are reported.
            /usr/bin/find -P "$path" -xdev -depth \( -type f -o -type d \) -delete
            rc=$?
        fi
        if [[ $rc != 0 ]] || cc_exists "$path"; then
            cc_preserve "$path" 'удаление не завершено (права, точка монтирования или изменения файлов)'
        else
            printf 'УДАЛЕНО   %q\n' "$path"
        fi
    done
}

cc_remove_empty_root() {
    local path=$1 entry
    cc_exists "$path" || return 0
    if ! cc_check_path "$path"; then cc_preserve "$path" "$CC_REASON"; return 0; fi
    if [[ ! -d $path || ! -r $path || ! -x $path || $(/usr/bin/stat -f '%u' "$path") != "$CC_UID" ]]; then
        cc_preserve "$path" 'невозможно проверить пустую корневую папку'; return 0
    fi
    for entry in "$path"/* "$path"/.[!.]* "$path"/..?*; do
        cc_exists "$entry" && return 0
    done
    # rmdir cannot remove any content, including something created concurrently.
    if /bin/rmdir -- "$path"; then
        printf 'УДАЛЕНО   %q (пустая папка)\n' "$path"
    else
        cc_preserve "$path" 'не удалось убрать пустую корневую папку'
    fi
}

cc_main() {
    local arg confirmation requested_apply=0 requested_dry=0
    CC_APPLY=0 CC_SCOPE=all CC_KEEP_KEYCHAIN=0 CC_PARTIAL=0
    CC_HOME='' CC_TEMP='' CC_SYSTEM_TEMP='' CC_UID='' CC_USER='' CC_KEYCHAIN=''
    CC_PATHS=() CC_KINDS=() CC_POLICIES=() CC_SIGNATURES=() CC_KNOWN=()
    while [[ $# -gt 0 ]]; do
        arg=$1; shift
        case "$arg" in
            --help|-h) cc_usage; return 0 ;;
            --apply) requested_apply=1 ;;
            --dry-run) requested_dry=1 ;;
            --yes) cc_error 'Обход подтверждения отключён. Запустите скрипт в терминале и подтвердите список.'; return 2 ;;
            --keep-keychain) CC_KEEP_KEYCHAIN=1 ;;
            --scope)
                [[ $# -gt 0 ]] || { cc_error 'После --scope нужно all, code или desktop.'; return 2; }
                CC_SCOPE=$1; shift
                case "$CC_SCOPE" in all|code|desktop) ;; *) cc_error 'Неизвестный --scope.'; return 2 ;; esac ;;
            *) cc_error "Неизвестный аргумент: $arg"; return 2 ;;
        esac
    done
    if [[ $requested_apply == 1 && $requested_dry == 1 ]]; then
        cc_error '--apply и --dry-run несовместимы.'; return 2
    fi
    cc_platform || return $?
    printf 'План для %q; приложения: %s\n' "$CC_HOME" "$CC_SCOPE"
    printf 'Удаление включает локальную историю, память, авторизацию и настройки.\n'
    printf 'Папки с отметкой УДАЛИТЬ будут удалены целиком, включая содержимое.\n'
    printf 'Сохранённые пути могут содержать следы прежней работы.\n\n'
    [[ $CC_SCOPE == desktop ]] || cc_code_manifest
    [[ $CC_SCOPE == code ]] || cc_desktop_manifest
    cc_keychain # Preview only: no Keychain API is called while CC_APPLY=0.
    printf '\nОбъектов файловой системы в плане: %s\n' "${#CC_PATHS[@]}"
    if [[ $CC_SCOPE != desktop ]] && [[ -d $CC_HOME/.claude ]] && cc_check_path "$CC_HOME/.claude"; then
        printf 'УДАЛИТЬ ЕСЛИ ПУСТО %q\n' "$CC_HOME/.claude"
    fi
    if [[ $CC_SCOPE != code ]] && [[ -d $CC_HOME/Library/Application\ Support/Claude ]] && cc_check_path "$CC_HOME/Library/Application Support/Claude"; then
        printf 'УДАЛИТЬ ЕСЛИ ПУСТО %q\n' "$CC_HOME/Library/Application Support/Claude"
    fi
    if [[ $requested_dry == 1 ]]; then
        printf 'Просмотр завершён. Ничего не удалено. Для очистки запустите без --dry-run.\n'
        return "$CC_PARTIAL"
    fi
    cc_check_processes || return $?
    [[ -t 0 ]] || { cc_error 'Подтверждение нужно ввести в терминале. Для просмотра используйте --dry-run.'; return 2; }
    printf '\nДля безвозвратного удаления перечисленных данных введите DELETE: '
    if ! IFS= read -r confirmation || [[ $confirmation != DELETE ]]; then
        printf 'Отменено. Ничего не удалено.\n'; return 0
    fi
    cc_check_processes || return $?
    CC_APPLY=1
    cc_delete_plan
    [[ $CC_SCOPE == desktop ]] || cc_remove_empty_root "$CC_HOME/.claude"
    [[ $CC_SCOPE == code ]] || cc_remove_empty_root "$CC_HOME/Library/Application Support/Claude"
    cc_keychain
    if [[ $CC_PARTIAL == 1 ]]; then
        printf '\nОчистка выполнена частично. Проверьте строки СОХРАНИТЬ.\n'
    else
        printf '\nПеречисленные локальные данные очищены.\n'
    fi
    printf 'Облачная история, проекты, программы и системные журналы сохраняются.\n'
    return "$CC_PARTIAL"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    set -o pipefail
    cc_main "$@"
    exit $?
fi
