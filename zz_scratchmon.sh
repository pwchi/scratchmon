#!/usr/bin/env bash
#===============================================================
# /etc/profile.d/zz_scratchmon.sh
#
# 使用者 SSH 登入時執行：
#   1) 以 df + timeout 查詢 scratch 整體使用率，超過門檻顯示警告
#   2) 若為 Lustre 檔案系統，額外用 lfs quota 顯示登入者自己的用量
#
# 兩者互相獨立：就算整體使用率沒超過門檻，個人用量還是會顯示；
# 就算個人用量查詢失敗(非 Lustre / 逾時)，整體警告仍正常運作。
#
# 注意：因為是登入當下即時查詢，若 scratch 為網路檔案系統
# (Lustre/BeeGFS/GPFS...) 且發生異常，登入會被拖慢，最多拖慢
# DF_TIMEOUT (+ LFS_TIMEOUT，若有觸發) 秒，逾時後放棄顯示，
# 不會卡住登入。
#
# 檔名以 zz_ 開頭，確保在其他 profile.d script 之後執行。
#
# ---- 部署權限要求 (務必遵守，否則有安全風險) ----
#   /etc/profile.d/zz_scratchmon.sh : root:root, 0755
#   /etc/scratchmon.conf            : root:root, 0644 (不可群組/其他人可寫)
#
#   設定檔會被 source 執行，等同執行任意 bash 指令。若設定檔可被
#   root 以外的人寫入，任何使用者都能植入指令，並在「每個登入
#   使用者」的 shell 裡、以該使用者的權限被執行。本 script 在載入
#   設定檔前會檢查 owner 與權限，不符合就拒絕載入並記錄到 syslog，
#   但這只是最後一道防線，正確的檔案權限仍是管理者的責任。
#
# ---- 本機測試 ----
# 加上 --demo 參數即可直接看到警告畫面效果，不需要 /etc 設定檔、
# 不需要真的有 scratch 掛載點、不需要互動式登入 shell：
#   bash ./zz_scratchmon.sh --demo
#   或 source ./zz_scratchmon.sh --demo
#
# ---- 已知相依套件 (Rocky Linux 8.10) ----
#   coreutils (df, timeout, stat), util-linux (mountpoint, findmnt,
#   logger), gawk, grep, sed；個人用量功能另需 Lustre client (lfs)；
#   動態分隔線寬度另需 ncurses-utils (tput)，minimal 安裝可能沒有，
#   缺少時會自動 fallback，不影響其餘功能。
#===============================================================

# 所有邏輯包在一個函式裡執行，執行完在檔案最後 unset 掉，
# 避免 PCT/USED/TOTAL/SCRATCH_MOUNT 這類變數以及內部函式
# 永久留在使用者的互動 shell 環境裡 (因為 profile.d 是用
# source 載入，不是獨立子行程，頂層變數/函式預設不會自動消失)。
_scratchmon() {
    local DEMO_MODE=0
    local CONF="/etc/scratchmon.conf"
    local CONF_OVERRIDDEN=0
    local SHOW_HELP=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --demo)
                DEMO_MODE=1
                shift
                ;;
            --conf=*)
                CONF="${1#--conf=}"
                CONF_OVERRIDDEN=1
                shift
                ;;
            --conf)
                CONF="${2:-}"
                CONF_OVERRIDDEN=1
                shift 2
                ;;
            -h|--help)
                SHOW_HELP=1
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    if [[ "$SHOW_HELP" -eq 1 ]]; then
        cat <<'HELP_EOF'
zz_scratchmon.sh - SSH 登入時顯示 scratch 空間使用率警告

用法:
  zz_scratchmon.sh [選項]

正常部署方式 (無參數):
  放在 /etc/profile.d/ 下由系統於使用者互動式登入 shell 時自動
  source 執行，讀取 /etc/scratchmon.conf 設定。

選項:
  --demo              以固定的測試資料顯示警告畫面效果，不需要
                       真的有 scratch 掛載點或使用率超標，也不需要
                       互動式登入 shell，可在任何終端機直接執行。
                       仍會讀取 --conf 指定 (或預設路徑) 的設定檔，
                       但 SCRATCH_MOUNT / THRESHOLD / DF_TIMEOUT 會
                       被強制覆寫以保證一定觸發，ANIMATION 等顯示
                       效果類參數則沿用設定檔實際值。

  --conf PATH         使用指定的設定檔，取代預設的
  --conf=PATH         /etc/scratchmon.conf。常見用法是搭配
                       --demo 在本機測試不同參數組合，不需要 root
                       權限、也不需要通過正式環境的檔案權限安全檢查
                       (該檢查只套用在預設路徑，因為那是會被自動
                       載入、需要防範被其他使用者竄改的路徑；用
                       --conf 明確指定則視為使用者自己的手動測試)。

  -h, --help          顯示這段說明並結束。

範例:
  # 快速看一次警告畫面長什麼樣子
  ./zz_scratchmon.sh --demo

  # 用自訂設定檔測試 (例如測試 ANIMATION=0 的效果)
  ./zz_scratchmon.sh --demo --conf ./test.conf

  # 部署到系統 (需要 root)
  sudo cp scratchmon.conf /etc/scratchmon.conf
  sudo cp zz_scratchmon.sh /etc/profile.d/
  sudo chmod 755 /etc/profile.d/zz_scratchmon.sh

詳細設定項目說明請見 scratchmon.conf 內的註解。
HELP_EOF
        return 0
    fi

    # 只在「互動式登入 shell + 有終端機」時顯示，避免 scp/rsync/
    # 非互動連線或指令化 SSH 執行被干擾。--demo 模式跳過這個限制，
    # 方便直接在任何終端機測試。
    if [[ "$DEMO_MODE" -ne 1 ]]; then
        case $- in
            *i*) : ;;
            *) return 0 ;;
        esac
        [[ -t 1 ]] || return 0
    fi

    # 簡單的非負整數驗證，設定檔數值型參數都靠這個檢查，
    # 避免打錯字/留空導致後面的算術比較讓 bash 噴錯誤
    # (會讓「每一個」登入的使用者都看到錯誤訊息，影響範圍很大)。
    _is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

    # 驗證數值是否為指定範圍內的整數，不合法就設回預設值並回傳非 0，
    # 呼叫端可用 `|| logger ...` 決定是否記錄，避免 A && B || C 這種
    # 容易誤讀 (且 C 在 B 失敗時也會執行) 的寫法。
    _validate_range() {
        local name="$1" min="$2" max="$3" default="$4"
        local val="${!name}"
        if _is_uint "$val" && (( val >= min && val <= max )); then
            return 0
        fi
        printf -v "$name" '%s' "$default"
        return 1
    }

    local SCRATCH_MOUNT THRESHOLD DF_TIMEOUT ANIMATION LOG_FAILURES SHOW_USER_QUOTA LFS_TIMEOUT

    # ---- 預設值 (設定檔不存在或缺項時使用) ----
    SCRATCH_MOUNT=""
    THRESHOLD=80
    DF_TIMEOUT=3
    ANIMATION=1
    LOG_FAILURES=1
    SHOW_USER_QUOTA=1
    LFS_TIMEOUT=5

    if [[ -n "$CONF" && -f "$CONF" ]]; then
        if [[ "$CONF_OVERRIDDEN" -eq 1 ]]; then
            # 透過 --conf 明確指定的設定檔屬於手動測試情境：是使用者
            # 自己指定要讀哪個檔案，不是 profile.d 自動載入預設路徑，
            # 不存在「其他使用者能悄悄置換設定檔」的攻擊情境，所以
            # 略過下面的 owner/權限檢查，方便本機測試不需要 root。
            # shellcheck source=/dev/null
            # 路徑為動態值 (/etc/scratchmon.conf 或 --conf 指定)，ShellCheck 無法靜態追蹤，此為刻意設計
            source "$CONF"
        else
            # 安全檢查：只信任 owner 是 root、且群組/其他人都不可寫的
            # 設定檔，否則等同讓任何能寫入該檔的人取得程式碼執行權。
            local conf_owner conf_perm conf_go conf_g conf_o
            conf_owner=$(stat -c '%u' "$CONF" 2>/dev/null)
            conf_perm=$(stat -c '%a' "$CONF" 2>/dev/null)
            conf_go="${conf_perm: -2}"
            conf_g="${conf_go:0:1}"
            conf_o="${conf_go:1:1}"

            if [[ "$conf_owner" == "0" && "$conf_g" =~ ^[0-7]$ && "$conf_o" =~ ^[0-7]$ \
                  && $(( conf_g & 2 )) -eq 0 && $(( conf_o & 2 )) -eq 0 ]]; then
                # shellcheck source=/dev/null
                source "$CONF"
            else
                [[ "$DEMO_MODE" -eq 1 ]] || logger -t scratchmon \
                    "SECURITY: refusing to source $CONF - must be owned by root and not writable by group/other (owner=$conf_owner perm=$conf_perm)"
            fi
        fi
    fi

    # 數值/布林參數驗證，任何一項不合法就退回安全預設值，
    # 並記一筆 log 提醒管理者去修正設定檔，而不是讓所有人
    # 登入時都看到 bash 錯誤訊息。demo 模式不記 log，避免
    # 純粹測試畫面效果時也在 syslog 留下雜訊。
    if [[ "$DEMO_MODE" -eq 1 ]]; then
        _validate_range THRESHOLD 0 100 80
        _validate_range LFS_TIMEOUT 1 60 5
    else
        _validate_range THRESHOLD 0 100 80 || logger -t scratchmon "invalid THRESHOLD in config, falling back to 80"
        _validate_range DF_TIMEOUT 1 60 3 || logger -t scratchmon "invalid DF_TIMEOUT in config, falling back to 3"
        _validate_range LFS_TIMEOUT 1 60 5 || logger -t scratchmon "invalid LFS_TIMEOUT in config, falling back to 5"
    fi
    [[ "$ANIMATION" == "0" || "$ANIMATION" == "1" ]] || ANIMATION=1
    [[ "$SHOW_USER_QUOTA" == "0" || "$SHOW_USER_QUOTA" == "1" ]] || SHOW_USER_QUOTA=1
    [[ "$LOG_FAILURES" == "0" || "$LOG_FAILURES" == "1" ]] || LOG_FAILURES=1

    if [[ "$DEMO_MODE" -eq 1 ]]; then
        # demo 模式：強制覆寫「保證觸發」相關的參數 (掛載點用 "/"
        # 保證查得到資料、THRESHOLD/DF_TIMEOUT 固定為安全值、
        # LOG_FAILURES 關閉避免測試訊息進 syslog)，這樣不管設定檔
        # 內容為何，一定看得到警告效果。
        #
        # 但 ANIMATION / SHOW_USER_QUOTA 這類「顯示效果」參數，
        # 沿用剛剛從設定檔讀到的實際值 (或預設值)，這樣才能用
        # --demo 測試「設定檔內動畫開關等效果」是否符合預期，
        # 不用真的觸發整體使用率超標才能測。
        SCRATCH_MOUNT="/"
        THRESHOLD=80
        DF_TIMEOUT=3
        LOG_FAILURES=0
    else
        # 若設定檔沒有指定掛載點，嘗試自動偵測：
        # 找出目前所有掛載點中，路徑含 "scratch" 字樣的第一個
        # (僅供測試/救急用，正式環境建議在 conf 明確指定 SCRATCH_MOUNT)
        if [[ -z "$SCRATCH_MOUNT" ]]; then
            SCRATCH_MOUNT=$(timeout "$DF_TIMEOUT" findmnt -rn -o TARGET 2>/dev/null | grep -i 'scratch' | head -n1)
        fi

        # 找不到掛載點就靜默結束，不要在登入時報錯干擾使用者
        [[ -n "$SCRATCH_MOUNT" ]] || return 0
    fi

    # ---------- 顏色與樣式 (提早定義，個人用量區塊也會用到) ----------
    local RED='\033[1;31m'
    local YELLOW='\033[1;33m'
    local CYAN='\033[1;36m'
    local WHITE='\033[1;37m'
    local BOLD='\033[1m'
    local BLINK='\033[5m'
    local RESET='\033[0m'
    local BG_RED='\033[41m'

    # ---------- 整體使用率查詢 ----------
    # mountpoint 本身也用 timeout 包起來，某些網路檔案系統異常時
    # 連 mountpoint 判斷都可能卡住
    local OVERALL_OK=0
    local PCT USED TOTAL DF_LINE

    if ! timeout "$DF_TIMEOUT" mountpoint -q "$SCRATCH_MOUNT" 2>/dev/null; then
        [[ "$LOG_FAILURES" -eq 1 ]] && logger -t scratchmon "mountpoint check failed or timed out: $SCRATCH_MOUNT"
    else
        DF_LINE=$(timeout "$DF_TIMEOUT" df -h --output=pcent,used,size "$SCRATCH_MOUNT" 2>/dev/null | tail -1)
        if [[ -z "${DF_LINE// /}" ]]; then
            [[ "$LOG_FAILURES" -eq 1 ]] && logger -t scratchmon "df timed out or failed: $SCRATCH_MOUNT (timeout=${DF_TIMEOUT}s)"
        else
            PCT=$(awk '{print $1}' <<< "$DF_LINE" | tr -d '%')
            USED=$(awk '{print $2}' <<< "$DF_LINE")
            TOTAL=$(awk '{print $3}' <<< "$DF_LINE")
            if [[ "$PCT" =~ ^[0-9]+$ ]]; then
                OVERALL_OK=1
            else
                [[ "$LOG_FAILURES" -eq 1 ]] && logger -t scratchmon "df output could not be parsed: $SCRATCH_MOUNT"
            fi
        fi
    fi

    if [[ "$DEMO_MODE" -eq 1 ]]; then
        # demo 模式下，畫面上假裝顯示一個高使用率的情境，
        # 比較貼近真實觸發警告時的樣子，也改個名字避免跟
        # 真實查詢到的 "/" 混淆
        OVERALL_OK=1
        PCT=87
        USED="187G"
        TOTAL="200G"
        SCRATCH_MOUNT="/scratch (demo)"
    fi

    local SHOW_OVERALL_WARNING=0
    [[ "$OVERALL_OK" -eq 1 ]] && (( PCT >= THRESHOLD )) && SHOW_OVERALL_WARNING=1

    # ---------- 個人用量查詢 (lfs quota，僅 Lustre 適用) ----------
    local QUOTA_LINE=""

    # 將人類可讀的容量字串 (如 11k, 45G, 1.5T) 換算成 bytes，
    # 用來跟整體 df 查到的總容量計算百分比。無法辨識時回傳空字串。
    # LC_ALL=C 避免系統上有問題/未安裝的 locale (例如某些環境設了
    # LC_ALL=zh_TW.UTF-8 但實際沒安裝該 locale 資料) 導致 awk 產生
    # setlocale 警告，或用逗號當小數點造成格式化異常。LC_ALL 的
    # 優先權比 LC_NUMERIC 高，所以要蓋 LC_ALL 才會真正生效。
    _human_to_bytes() {
        local val="$1" num unit mul
        num=$(grep -oE '^[0-9.]+' <<< "$val")
        unit=$(grep -oE '[A-Za-z]+$' <<< "$val" | tr '[:lower:]' '[:upper:]')
        [[ -n "$num" ]] || return 1
        case "$unit" in
            K) mul=1024 ;;
            M) mul=$((1024*1024)) ;;
            G) mul=$((1024*1024*1024)) ;;
            T) mul=$((1024*1024*1024*1024)) ;;
            P) mul=$((1024*1024*1024*1024*1024)) ;;
            "") mul=1 ;;
            *) return 1 ;;
        esac
        LC_ALL=C awk -v n="$num" -v m="$mul" 'BEGIN{printf "%.0f", n*m}'
    }

    _query_user_quota() {
        [[ "$SHOW_USER_QUOTA" -eq 1 ]] || return 0

        if [[ "$DEMO_MODE" -eq 1 ]]; then
            # demo 模式直接假造一筆資料，展示顯示效果，不實際呼叫 lfs
            QUOTA_LINE="demo_user|45G"
            return 0
        fi

        command -v lfs >/dev/null 2>&1 || return 0

        local fstype
        fstype=$(timeout "$DF_TIMEOUT" findmnt -no FSTYPE "$SCRATCH_MOUNT" 2>/dev/null)
        [[ "$fstype" == "lustre" ]] || return 0

        local who
        who=$(id -un)

        local Q_OUT
        Q_OUT=$(timeout "$LFS_TIMEOUT" lfs quota -uh "$who" "$SCRATCH_MOUNT" 2>/dev/null)
        if [[ -z "$Q_OUT" ]]; then
            [[ "$LOG_FAILURES" -eq 1 ]] && logger -t scratchmon "lfs quota timed out or failed: $SCRATCH_MOUNT (user=$who)"
            return 0
        fi

        # lfs quota -h 輸出格式範例 (下列帳號/UID/數值皆為虛構範例，
        # 僅用來說明格式；欄位順序與寬度已對照真實 Lustre 輸出驗證過)：
        #   Disk quotas for usr alice (uid 10000):
        #        Filesystem    used   quota   limit   grace   files   quota   limit   grace
        #          /scratch    128k      0k      0k       -       3       0       0       -
        #
        # 注意重點：
        #   1) -h 輸出的單位是小寫 (128k, 不是 128K)，_human_to_bytes() 有處理大小寫
        #   2) 只需要「used」這個欄位 (固定第 2 欄)，用固定欄位位置取值，
        #      避免掛載點路徑本身含數字(如 /scratch2)時被誤判為用量欄位
        #   3) quota/limit 欄位為 0 代表該檔案系統沒有針對此帳號另外
        #      設定個人配額 (使用系統預設值)，不代表配額真的是 0；
        #      這種情況下 quota/limit 這兩個數字對本腳本沒有意義，
        #      只取用 used 欄位
        local SIZE_RE='^[0-9]+(\.[0-9]+)?[KMGTPkmgtp]?$'
        local DATA_LINE
        DATA_LINE=$(echo "$Q_OUT" | grep -Ei '[0-9.]+[kmgtp]?[[:space:]]+[0-9.]+[kmgtp]?[[:space:]]+[0-9.]+[kmgtp]?' | head -1)

        local USED_Q=""
        [[ -n "$DATA_LINE" ]] && USED_Q=$(awk '{print $2}' <<< "$DATA_LINE")

        if [[ -n "$USED_Q" && "$USED_Q" =~ $SIZE_RE ]]; then
            QUOTA_LINE="${who}|${USED_Q}"
        else
            # 解析失敗，仍保留原始輸出前兩行，避免完全沒有資訊可看
            [[ "$LOG_FAILURES" -eq 1 ]] && logger -t scratchmon "lfs quota output could not be parsed: $SCRATCH_MOUNT (user=$who)"
            QUOTA_LINE="RAW|$(echo "$Q_OUT" | sed -n '2,3p' | tr '\n' ' ' | sed 's/  */ /g')"
        fi
    }

    _query_user_quota

    # 如果整體沒超標，也沒有個人用量資料可顯示，就什麼都不做，安靜結束
    if [[ "$SHOW_OVERALL_WARNING" -ne 1 && -z "$QUOTA_LINE" ]]; then
        unset -f _human_to_bytes _query_user_quota _is_uint _validate_range 2>/dev/null
        return 0
    fi

    # ---------- 動態進度條 (只在整體警告觸發時顯示) ----------
    if [[ "$SHOW_OVERALL_WARNING" -eq 1 && "$ANIMATION" -eq 1 ]]; then
        local BAR_LEN=40 p filled empty COLOR
        for (( p=0; p<PCT; p+=4 )); do
            filled=$(( p * BAR_LEN / 100 ))
            empty=$(( BAR_LEN - filled ))
            COLOR=$YELLOW
            (( p >= 60 )) && COLOR=$RED
            printf "\rChecking %s usage [${COLOR}%s${RESET}%s] %3d%%" \
                "$SCRATCH_MOUNT" \
                "$(printf '%.0s█' $(seq 1 "$filled" 2>/dev/null))" \
                "$(printf '%.0s░' $(seq 1 "$empty" 2>/dev/null))" \
                "$p"
            sleep 0.02
        done
        # 最後一定強制顯示真正的 PCT 當作定格畫面，不能只靠迴圈的
        # 步進值 (+=4) 自然跑到，因為 PCT 不一定是 4 的倍數
        # (例如 87% 用 +=4 只會跑到 84% 就因為 88>87 而跳出迴圈)，
        # 否則動畫定格數字會跟下面警告框顯示的真實使用率對不上。
        p=$PCT
        filled=$(( p * BAR_LEN / 100 ))
        empty=$(( BAR_LEN - filled ))
        COLOR=$YELLOW
        (( p >= 60 )) && COLOR=$RED
        printf "\rChecking %s usage [${COLOR}%s${RESET}%s] %3d%%" \
            "$SCRATCH_MOUNT" \
            "$(printf '%.0s█' $(seq 1 "$filled" 2>/dev/null))" \
            "$(printf '%.0s░' $(seq 1 "$empty" 2>/dev/null))" \
            "$p"
        printf "\n\n"
    fi

    # ---------- 醒目警告框 (整體使用率超標時) ----------
    if [[ "$SHOW_OVERALL_WARNING" -eq 1 ]]; then
        # 不做左右邊框對齊的封閉框：SSH client 終端機寬度不一，Action
        # 訊息文字又比較長，遇到窄視窗時終端機會自動換行，硬要對齊的
        # 右邊「│」反而會被攔腰截斷、飄到下一行開頭，比沒有框線更難看。
        # 改用「上下分隔線 + 醒目標題列」的簡單排版，讓內容依終端機
        # 寬度自然換行，不會有殘留的邊框符號卡在奇怪的位置。
        local TERM_COLS SEP
        TERM_COLS=$(tput cols 2>/dev/null)
        [[ "$TERM_COLS" =~ ^[0-9]+$ ]] || TERM_COLS=60
        (( TERM_COLS > 80 )) && TERM_COLS=80
        SEP=$(printf '%.0s─' $(seq 1 "$TERM_COLS"))

        echo -e "${RED}${SEP}${RESET}"
        echo -e "${BG_RED}${WHITE}${BLINK} !!  WARNING: SCRATCH SPACE ALMOST FULL  !! ${RESET}"
        echo ""
        echo -e "Mount point : ${YELLOW}${SCRATCH_MOUNT}${RESET}"
        echo -e "Usage       : ${BG_RED}${WHITE}${BOLD}${PCT}%${RESET}  (used ${USED} / total ${TOTAL})"
        echo -e "Action      : I/O performance may degrade once /scratch usage exceeds ${THRESHOLD}%. Please clean up your personal files in /scratch ASAP."
        echo -e "${RED}${SEP}${RESET}"
    fi

    # ---------- 個人用量資訊 (與整體警告是否觸發無關，各自獨立顯示) ----------
    if [[ -n "$QUOTA_LINE" ]]; then
        local Q_USER Q_USED
        IFS='|' read -r Q_USER Q_USED <<< "$QUOTA_LINE"
        if [[ "$Q_USER" == "RAW" ]]; then
            echo -e "${CYAN}${BOLD}Your usage on ${SCRATCH_MOUNT} (parse failed, showing raw output)${RESET}"
            echo -e "  ${Q_USED}"
        else
            # 只有整體總容量查得到時 (真實環境 OVERALL_OK=1，或 demo 模式)
            # 才能算出「佔整體百分比」，查不到就只顯示用量本身
            local PCT_OF_TOTAL="" USED_BYTES TOTAL_BYTES
            if [[ "$OVERALL_OK" -eq 1 || "$DEMO_MODE" -eq 1 ]]; then
                USED_BYTES=$(_human_to_bytes "$Q_USED")
                TOTAL_BYTES=$(_human_to_bytes "$TOTAL")
                if [[ -n "$USED_BYTES" && -n "$TOTAL_BYTES" && "$TOTAL_BYTES" -gt 0 ]]; then
                    PCT_OF_TOTAL=$(LC_ALL=C awk -v u="$USED_BYTES" -v t="$TOTAL_BYTES" 'BEGIN{printf "%.2f", (u/t)*100}')
                fi
            fi

            if [[ -n "$PCT_OF_TOTAL" ]]; then
                echo -e "${CYAN}${BOLD}Your usage on ${SCRATCH_MOUNT}${RESET} (${Q_USER}): ${YELLOW}${Q_USED}${RESET} used  (${PCT_OF_TOTAL}% of total capacity)"
            else
                echo -e "${CYAN}${BOLD}Your usage on ${SCRATCH_MOUNT}${RESET} (${Q_USER}): ${YELLOW}${Q_USED}${RESET} used"
            fi
        fi
    fi

    echo ""

    unset -f _human_to_bytes _query_user_quota _is_uint _validate_range 2>/dev/null
}

_scratchmon "$@"
unset -f _scratchmon
