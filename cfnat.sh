#!/bin/bash
export LANG=en_US.UTF-8

# 定义颜色
re='\e[0m'
red='\e[1;91m'
white='\e[1;97m'
green='\e[1;32m'
yellow='\e[1;33m'
purple='\e[1;35m'
skyblue='\e[1;96m'

# 配置文件路径
cfnat_file=$HOME/cfnat
config_file=$cfnat_file/cfnat.conf
ps=""
Androidps=""
# 筛选数据中心，多个用逗号隔开（对应 cfnat -colo，默认 SJC,LAX,HKG）
cfnatcolo="SJC,LAX,HKG,KHH,NRT,SEA,FRA,MAD"
# 本地监听端口（对应 cfnat -addr 的端口，默认 1234）
cfnatport="1234"
# 有效延迟（毫秒），超过则断开（对应 cfnat -delay，默认 300）
cfnatdelay="300"
# 转发目标端口（对应 cfnat -port，默认 443）
tport="443"
# IP 版本 4 或 6（对应 cfnat -ips，默认 4）
ips="4"
# 本地监听IP（对应 cfnat -addr 的IP，默认 0.0.0.0 监听所有接口）
addr="0.0.0.0"
# HTTP/HTTPS 响应状态码（对应 cfnat -code，默认 200）
code="200"
# 响应状态码检查的域名地址（对应 cfnat -domain，默认 cloudflaremirrors.com/debian）
domain="cloudflaremirrors.com/debian"
# 提取的有效IP数量（对应 cfnat -ipnum，默认 20）
ipnum="20"
# 目标负载 IP 数量（对应 cfnat -num，默认 5）
num="5"
# 是否随机生成IP（对应 cfnat -random，默认 true）
random="true"
# 并发请求最大协程数（对应 cfnat -task，默认 100）
task="100"
# 是否为 TLS 端口（对应 cfnat -tls，默认 true）
tls="true"
# GitHub 下载代理前缀（如 https://ghproxy.com/ ），需以 / 结尾，留空则直连
# 首次安装时 conf 不存在，可通过环境变量 GITHUB_PROXY 传入代理
github_proxy="${GITHUB_PROXY:-}"

################################################################

# 安装依赖包
install() {
    if [ $# -eq 0 ]; then
        echo -e "${red}未提供软件包参数!${re}"
        return 1
    fi

    for package in "$@"; do
        if command -v "$package" &>/dev/null; then
            echo -e "${green}${package}已经安装了！${re}"
            continue
        fi
        echo -e "${yellow}正在安装 ${package}...${re}"

        if [ -n "$PREFIX" ] && [ -d "$PREFIX" ] && echo "$PREFIX" | grep -q "/data/data/com.termux/files"; then
            pkg install -y "$package"
        elif command -v apt &>/dev/null; then
            apt install -y "$package"
        elif command -v dnf &>/dev/null; then
            dnf install -y "$package"
        elif command -v yum &>/dev/null; then
            yum install -y "$package"
        elif command -v apk &>/dev/null; then
            apk add "$package"
        elif [ -f /etc/openwrt_release ]; then
            opkg update
            opkg install coreutils coreutils-nohup crontab
        else
            echo -e"${red}暂不支持你的系统!${re}"
            return 1
        fi
    done

    return 0
}

# 选择客户端 CPU 架构
archAffix(){
    if [ -n "$PREFIX" ] && [ -d "$PREFIX" ] && echo "$PREFIX" | grep -q "/data/data/com.termux/files"; then
        echo 'termux'
    else
        case "$(uname -m)" in
        i386 | i686 ) echo '386' ;;
        x86_64 | amd64 ) echo 'amd64' ;;
        armv7 ) echo 'arm' ;;
        armv8 | arm64 | aarch64 ) echo 'arm64' ;;
        s390x ) echo 's390x' ;;
        * ) echo '未知' ;;
        esac
    fi
}

# 等待用户返回
break_end() {
    echo -e "${green}执行完成${re}"
    echo -e "${yellow}按任意键返回...${re}"
    # 交互终端(stdin是tty)：等按键；管道/非终端(EOF)：直接继续不卡死
    if [ -t 0 ]; then
        read -n 1 -s -r -p ""
        echo ""
    fi
    clear
}

# 纯 shell 合并多个 IP/CIDR 源，去重并合并相邻段
# 等效 Python ipaddress.collapse_addresses，已验证输出一致
# 用法: merge_ips file1.txt file2.txt ... > output.txt
merge_ips() {
    awk -v OFS='\t' '{
        s=$0; sub(/\r$/,"",s)
        if(s==""||s~/^#/)next
        n=split(s,p,"/"); split(p[1],o,".")
        ip=o[1]*16777216+o[2]*65536+o[3]*256+o[4]
        mask=(n==1)?32:int(p[2]); hb=32-mask
        if(hb==32){start=0;end=4294967295}
        else{b=1;for(i=0;i<hb;i++)b*=2;start=ip-(ip%b);end=start+b-1}
        print start,end
    }' "$@" | sort -n -k1,1 | awk -v OFS='\t' '
    NF==2{if(NR==1){cs=$1;ce=$2;next}
          if($1<=ce+1){if($2>ce)ce=$2}else{print cs,ce;cs=$1;ce=$2}}
    END{print cs,ce}' | awk -v OFS='\t' '
    BEGIN{p[0]=1;for(k=1;k<=32;k++)p[k]=p[k-1]*2}
    function i2(n){return int(n/16777216)"."int((n%16777216)/65536)"."int((n%65536)/256)"."(n%256)}
    {s=$1;e=$2;while(s<=e){mk=0;for(k=0;k<=32;k++){if(p[k]>(e-s+1))break;if(s%p[k]==0)mk=k}
        print i2(s)"/"(32-mk);s+=p[mk]}}'
}

# 检测 Docker 环境状态
# 返回: 0=就绪, 1=无docker命令, 2=daemon未运行, 3=无compose
check_docker_env() {
    command -v docker &>/dev/null || return 1
    docker info &>/dev/null 2>&1 || return 2
    docker compose version &>/dev/null 2>&1 || return 3
    return 0
}

# 检测 Docker 版 cfnat 是否在运行（无 Docker 环境安全跳过，返回 1）
docker_cfnat_running() {
    check_docker_env || return 1
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q 'cfnat'
}

# 校验下载文件有效性：存在且大小 >= 100 字节
# 防止 curl 把 404 错误页（通常仅十几字节）误判为下载成功
valid_file() {
    local f="$1"
    [ -s "$f" ] && [ "$(stat -c%s "$f" 2>/dev/null || echo 0)" -ge 100 ]
}

# 安装cfnat
install_cfnat(){
    if [ -n "$1" ]; then 
        install curl nohup crontab
    else
        echo -e "脚本所需依赖包 ${yellow}curl nohup crontab${re}"
        read -p "是否允许脚本自动安装以上所需的依赖包(Y): " install_apps
        install_apps=${install_apps^^} # 转换为大写
        if [ "$install_apps" == "Y" ]; then
            install curl nohup crontab
        fi
    fi

    # 检测 $cfnat_file 文件夹是否存在
    if [ ! -d $cfnat_file ]; then
        # 如果不存在，则创建该文件夹
        mkdir $cfnat_file
        echo "目录 $cfnat_file 已创建。"
    fi

    # 检测 $cfnat_file/locations.json 是否存在且有效
    if ! valid_file $cfnat_file/locations.json; then
        rm -f $cfnat_file/locations.json
        # 主源: 090227.xyz
        curl --connect-timeout 10 --max-time 60 -SL https://cf.090227.xyz/locations -o $cfnat_file/locations.json
        if ! valid_file $cfnat_file/locations.json; then
            rm -f $cfnat_file/locations.json
            # 备用源1: cmliussss 仓库
            curl --connect-timeout 10 --max-time 60 -ksSL https://raw.cmliussss.com/cfnat/locations.json -o $cfnat_file/locations.json
        fi
        if ! valid_file $cfnat_file/locations.json; then
            rm -f $cfnat_file/locations.json
            # 备用源2: GitHub yanghou73/cfnat 仓库（如配置了 github_proxy 则通过代理下载）
            curl --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 2 --retry-all-errors -SL ${github_proxy}https://raw.githubusercontent.com/yanghou73/cfnat/main/locations.json -o $cfnat_file/locations.json
        fi

        if ! valid_file $cfnat_file/locations.json; then
            rm -f $cfnat_file/locations.json
            echo "locations.json 下载失败。"
        else
            echo "locations.json 下载完成。"
        fi
    else
        echo "locations.json 准备就绪。"
    fi

    # 检测 $cfnat_file/cfnat 是否存在且有效
    if ! valid_file $cfnat_file/cfnat; then
        rm -f $cfnat_file/cfnat
        # 从 GitHub 仓库 ./build 下载文件
        # 仓库地址: https://github.com/yanghou73/cfnat
        # 如配置了 github_proxy，会自动拼接在源链接之前以走代理下载
        if [ ${Architecture} = "termux" ]; then
            curl --connect-timeout 10 --max-time 120 --retry 3 --retry-delay 2 --retry-all-errors -SL ${github_proxy}https://raw.githubusercontent.com/yanghou73/cfnat/main/build/cfnat-termux -o $cfnat_file/cfnat
        else
            curl --connect-timeout 10 --max-time 120 --retry 3 --retry-delay 2 --retry-all-errors -SL ${github_proxy}https://raw.githubusercontent.com/yanghou73/cfnat/main/build/cfnat-linux-${Architecture} -o $cfnat_file/cfnat
        fi
        if valid_file $cfnat_file/cfnat; then
            chmod +x $cfnat_file/cfnat
            echo "cfnat主程序 下载完成。"
        else
            rm -f $cfnat_file/cfnat
            echo "cfnat主程序 下载失败。"
        fi
    else
        chmod +x $cfnat_file/cfnat 2>/dev/null
        echo "cfnat主程序 准备就绪。"
    fi

    # 检测 $cfnat_file/cfnat.conf 是否存在且有效
    # 不存在/无效则从 GitHub 下载 cfnat.conf.example → cfnat.conf（与二进制版本配套的默认配置）
    if ! valid_file "$config_file"; then
        rm -f "$config_file"
        curl --connect-timeout 10 --max-time 30 --retry 3 --retry-delay 2 --retry-all-errors -SL ${github_proxy}https://raw.githubusercontent.com/yanghou73/cfnat/main/cfnat.conf.example -o "$config_file"
        if valid_file "$config_file"; then
            echo "cfnat.conf 下载完成（请运行菜单5配置个性化参数）。"
        else
            rm -f "$config_file"
            echo "cfnat.conf 下载失败。"
        fi
    else
        echo "cfnat.conf 准备就绪。"
    fi
}

# 卸载cfnat
# 仅删除 4 个运行时产物（二进制/配置/IP库/位置数据），保留 cfnat.sh 脚本本身
# 避免 rm -rf 自删正在运行的脚本导致不可预测行为；卸载后菜单自动变为"一键安装"，
# 用户可直接 bash cfnat.sh → 选1 重装，无需重新 curl 下载脚本
uninstall_cfnat(){
    kill_cfnat
    delete_cron
    rm -f "$cfnat_file/cfnat"
    rm -f "$cfnat_file/cfnat.conf"
    rm -f "$cfnat_file/ips-v4.txt"
    rm -f "$cfnat_file/locations.json"
    echo -e "${green}cfnat 已卸载${re}"
    echo -e "${yellow}脚本本身(cfnat.sh)已保留，可重新运行 bash cfnat.sh 重装${re}"
}

check_cfnat(){
    # 读取 release（留空则自动检测）
    if [ -f "$config_file" ]; then
        release=$(grep '^release=' "$config_file" | cut -d'=' -f2)
    fi
    if [ -z "$release" ]; then
        if [[ -f /etc/redhat-release ]]; then
            release="Centos" 
        elif grep -q -E -i "alpine" /etc/issue 2>/dev/null; then 
            release="alpine" 
        elif grep -q -E -i "debian" /etc/issue 2>/dev/null; then 
            release="Debian" 
        elif grep -q -E -i "ubuntu" /etc/issue 2>/dev/null; then 
            release="Ubuntu" 
        elif grep -q -E -i "centos|red hat|redhat" /etc/issue 2>/dev/null; then 
            release="Centos" 
        elif grep -q -E -i "openwrt" /proc/version 2>/dev/null; then 
            release="OpenWRT" 
        elif grep -q -E -i "debian" /proc/version 2>/dev/null; then 
            release="Debian" 
        elif grep -q -E -i "ubuntu" /proc/version 2>/dev/null; then 
            release="Ubuntu" 
        elif grep -q -E -i "centos|red hat|redhat" /proc/version 2>/dev/null; then 
            release="Centos" 
        else  
            site_release
        fi
    fi

    # 读取 Architecture（留空则自动检测）
    if [ -f "$config_file" ]; then
        Architecture=$(grep '^Architecture=' "$config_file" | cut -d'=' -f2)
    fi
    if [ -z "$Architecture" ]; then
        Architecture=$(archAffix)
        if [ "$Architecture" = "未知"  ]; then
            site_Architecture
        fi
    fi

    if [ ${Architecture} = "termux" ]; then
        #install net-tools
        lanip=$(ifconfig | grep -Eo 'inet (192\.168|10\.|172\.(1[6-9]|2[0-9]|3[0-1]))[0-9.]+' | awk '{print $2}')
        Androidps="${yellow} 安卓手机推荐使用 ${green}调试运行 ${yellow}来执行任务"
    else
        lanip=$(ip -4 addr | grep -Eo 'inet (192\.168|10\.|172\.(1[6-9]|2[0-9]|3[0-1]))[0-9.]+/[0-9]+' | awk '{print $2}' | cut -d'/' -f1)
    fi
    # 检测 $cfnat_file 文件夹是否存在
    if [ -d $cfnat_file ]; then
        # 检测 $cfnat_file/cfnat 文件是否存在
        if [ -f $cfnat_file/cfnat ] && [ -f $cfnat_file/locations.json ]; then
            InstallationStatus="${green}已安装"
            OneclickInstallation="${red}一键卸载"

            if [ -f "$config_file" ]; then
                # 如果存在，读取各字段内容
                colo=$(grep '^colo=' "$config_file" | cut -d'=' -f2)
                port=$(grep '^port=' "$config_file" | cut -d'=' -f2)
                delay=$(grep '^delay=' "$config_file" | cut -d'=' -f2)
                tport=$(grep '^tport=' "$config_file" | cut -d'=' -f2)
                ips=$(grep '^ips=' "$config_file" | cut -d'=' -f2)
                addr=$(grep '^addr=' "$config_file" | cut -d'=' -f2-)
                code=$(grep '^code=' "$config_file" | cut -d'=' -f2)
                domain=$(grep '^domain=' "$config_file" | cut -d'=' -f2-)
                ipnum=$(grep '^ipnum=' "$config_file" | cut -d'=' -f2)
                num=$(grep '^num=' "$config_file" | cut -d'=' -f2)
                random=$(grep '^random=' "$config_file" | cut -d'=' -f2)
                task=$(grep '^task=' "$config_file" | cut -d'=' -f2)
                tls=$(grep '^tls=' "$config_file" | cut -d'=' -f2)
                github_proxy=$(grep '^github_proxy=' "$config_file" | cut -d'=' -f2-)
                auto_update_hour=$(grep '^auto_update_hour=' "$config_file" | cut -d'=' -f2)
            fi
            # conf 不存在时变量保持脚本顶部默认值，不创建conf（由 install_cfnat 从 GitHub 下载 conf.example）
            cfnatcolo=${colo:-SJC,LAX,HKG}
            cfnatport=${port:-1234}
            cfnatdelay=${delay:-300}
            # 留空则使用默认值
            tport=${tport:-443}
            ips=${ips:-4}
            addr=${addr:-0.0.0.0}
            code=${code:-200}
            domain=${domain:-cloudflaremirrors.com/debian}
            ipnum=${ipnum:-20}
            num=${num:-5}
            random=${random:-true}
            task=${task:-100}
            tls=${tls:-true}
            # 规范化代理 URL：非空且不以 / 结尾时补 /，避免拼接后 URL 错乱
            if [ -n "$github_proxy" ] && [[ "$github_proxy" != */ ]]; then
                github_proxy="${github_proxy}/"
            fi

            if [ -f "$cfnat_file/ips-v4.txt" ]; then
                # 统计 IP 库段数与 IP 总数（不再用行数猜 ASN）
                local seg=$(wc -l < "$cfnat_file/ips-v4.txt" 2>/dev/null)
                local ipcnt=$(awk -F'/' '{hb=32-$2;b=1;for(i=0;i<hb;i++)b*=2;sum+=b} END{print sum}' "$cfnat_file/ips-v4.txt" 2>/dev/null)
                if [ -n "$ipcnt" ] && [ "$ipcnt" -gt 0 ] 2>/dev/null; then
                    IPLibrary="${green}合并集 ${seg}段/$((ipcnt/10000))万IP"
                else
                    IPLibrary="${red}合并集异常"
                fi
            else
                up_merged
            fi

        else
            InstallationStatus="${red}未安装"
            OneclickInstallation="${green}一键安装"
        fi
    else
        InstallationStatus="${red}未安装"
        OneclickInstallation="${green}一键安装"
    fi

    if [ "$release" = "OpenWRT" ]; then
        cfnatpid=$(pgrep -f "./cfnat -colo")
        # 检查是否找到了 PID
        if [ -n "$cfnatpid" ]; then
            statecfnat="${green}运行中"
        else
            statecfnat="${red}未运行"
        fi
    else
        # 检测 $cfnat_file/cfnat 程序是否正在运行
        if pgrep -x "cfnat" > /dev/null; then
            # 如果正在运行，赋值
            statecfnat="${green}运行中"
        else
            # 如果未运行，赋值
            statecfnat="${red}未运行"
        fi
    fi
}

add_cron(){
    if [ "${Architecture}" != "termux" ]; then
        delete_cron
        # 保活任务（每5分钟，路径用 $cfnat_file 确保 crontab 能找到 cfnat.sh）
        # >/dev/null 2>&1 静默运行，避免 cron 邮件/syslog 日志堆积
        cron_cfnat="*/5 * * * * cd $cfnat_file && bash cfnat.sh $cfnatcolo >/dev/null 2>&1"
        (crontab -l 2>/dev/null; echo "$cron_cfnat") | crontab -
        echo "添加 crontab 保活任务 $cron_cfnat"
        # 定时更新 IP 库任务（仅启用时注册）
        if [ -n "$auto_update_hour" ]; then
            local h2=$(printf '%02d' "$auto_update_hour")
            cron_update="0 $auto_update_hour * * * cd $cfnat_file && bash cfnat.sh --update-ips >/dev/null 2>&1"
            (crontab -l 2>/dev/null; echo "$cron_update") | crontab -
            echo "添加 crontab 定时更新任务 每天 ${h2}:00"
        fi
    fi
}

delete_cron(){
    if [ "${Architecture}" != "termux" ]; then
        crontab -l | grep -v 'bash cfnat.sh' | crontab -
        echo "清理 crontab 守护任务"
    fi
}

up_merged(){
    # 6 源并集合并去重（AS13335 两源 + AS209242/AS24429/AS35916/AS199524）
    # 尽力合并：失败的源跳过，全失败则保留旧库不覆盖
    echo "下载 IP 库（6 源合并去重）"
    local tmp_dir="$cfnat_file/.update_tmp"
    rm -rf "$tmp_dir" 2>/dev/null
    mkdir -p "$tmp_dir"
    # 源列表：名称|URL（cmliussss 需带浏览器 UA，否则被拒）
    local sources=(
        "AS13335_cmliussss|https://raw.cmliussss.com/cfnat/ips-v4.txt"
        "AS13335_asn2cidr|https://asn2cidr.090227.xyz/AS13335"
        "AS209242|https://asn2cidr.090227.xyz/AS209242"
        "AS24429|https://asn2cidr.090227.xyz/AS24429"
        "AS35916|https://asn2cidr.090227.xyz/AS35916"
        "AS199524|https://asn2cidr.090227.xyz/AS199524"
    )
    # 并行下载
    for src in "${sources[@]}"; do
        local name="${src%%|*}"
        local url="${src##*|}"
        (
            if [[ "$url" == *cmliussss* ]]; then
                # cmliussss: 服务器不稳定(常502/握手失败)，加 -k 跳过证书校验；冗余源(asn2cidr 已覆盖 AS13335)
                # 提到 --retry 2(共3次) 提升捕获冗余 AS13335 IP 的概率
                curl --connect-timeout 8 --max-time 30 --retry 2 --retry-delay 1 --retry-all-errors -ksSL -A "Mozilla/5.0" "$url" -o "$tmp_dir/$name.txt"
            else
                curl --connect-timeout 15 --max-time 90 --retry 3 --retry-delay 2 --retry-all-errors -sSL "$url" -o "$tmp_dir/$name.txt"
            fi
        ) &
    done
    wait
    # 统计成功源（valid_file 过滤 404 错误页等小文件，防止污染合并结果）
    local ok=0
    local files=()
    for src in "${sources[@]}"; do
        local name="${src%%|*}"
        if valid_file "$tmp_dir/$name.txt"; then
            files+=("$tmp_dir/$name.txt")
            ok=$((ok+1))
            echo -e "  ${green}✓${re} $name ($(wc -l < "$tmp_dir/$name.txt") 行)"
        else
            rm -f "$tmp_dir/$name.txt"
            echo -e "  ${red}✗${re} $name 下载失败/无效，跳过"
        fi
    done

    local rc=0
    if [ $ok -eq 0 ]; then
        echo -e "${red}所有源下载失败，保留旧 IP 库不变${re}"
        rc=1
    else
        # 合并去重写入临时文件，再原子 mv 覆盖（防与 crontab 守护竞态）
        merge_ips "${files[@]}" > "$tmp_dir/ips-v4.merged"
        local seg=$(wc -l < "$tmp_dir/ips-v4.merged")
        if [ "$seg" -lt 10 ]; then
            echo -e "${red}合并后仅 $seg 段，疑似异常，保留旧 IP 库不变${re}"
            rc=1
        else
            mv "$tmp_dir/ips-v4.merged" "$cfnat_file/ips-v4.txt"
            local ipcnt=$(awk -F'/' '{hb=32-$2;b=1;for(i=0;i<hb;i++)b*=2;sum+=b} END{print sum}' "$cfnat_file/ips-v4.txt")
            echo -e "${green}IP 库已更新：${re}${ok}/6 源，${seg} 段，${ipcnt} 个 IP"
            # cfnat 运行中则自动重启加载新 IP（cfnat 运行中不重载文件）
            if docker_cfnat_running; then
                # Docker 版运行中：重启容器（需挂载 ips-v4.txt 才能加载宿主机更新的 IP）
                echo -e "${yellow}Docker 版 cfnat 运行中，重启容器以加载新 IP...${re}"
                docker restart cfnat 2>/dev/null
                echo -e "${green}Docker 容器已重启${re}"
            else
                # 脚本版运行中：kill + restart
                local running=0
                if [ "$release" = "OpenWRT" ]; then
                    pgrep -f "./cfnat -colo" >/dev/null 2>&1 && running=1
                else
                    pgrep -x "cfnat" >/dev/null 2>&1 && running=1
                fi
                if [ $running -eq 1 ]; then
                    echo -e "${yellow}cfnat 运行中，重启以加载新 IP...${re}"
                    kill_cfnat
                    go_cfnat
                    echo -e "${green}cfnat 已重启，新 IP 库已生效${re}"
                fi
            fi
        fi
    fi
    rm -rf "$tmp_dir"
    return $rc
}

config_cfnat(){
    echo "电信 推荐 SJC,LAX"
    echo "移动/联通 推荐 HKG"
    # 读取并处理数据中心输入
    read -p "输入筛选数据中心（多个数据中心用逗号隔开，留空则使用 SJC,LAX,HKG）: " colo
    colo=${colo:-"SJC,LAX,HKG"}
    colo=${colo^^}
    # 更新配置文件中的 colo 参数
    if grep -q "^colo=" "$config_file"; then
        sed -i "s/^colo=.*/colo=${colo}/" "$config_file"
    else
        echo "colo=${colo}" >> "$config_file"
    fi

    # 读取并处理端口输入
    echo ""
    read -p "输入本地监听端口（默认 1234）: " port
    port=${port:-1234}
    # 更新配置文件中的 port 参数
    if grep -q "^port=" "$config_file"; then
        sed -i "s/^port=.*/port=${port}/" "$config_file"
    else
        echo "port=${port}" >> "$config_file"
    fi

    # 读取并处理延迟输入
    echo ""
    echo "电信 有效延迟推荐 300"
    echo "移动/联通 有效延迟可尝试 100"
    read -p "输入有效延迟（毫秒），超过此延迟将断开连接（默认 300）: " delay
    delay=${delay:-300}
    # 更新配置文件中的 delay 参数
    if grep -q "^delay=" "$config_file"; then
        sed -i "s/^delay=.*/delay=${delay}/" "$config_file"
    else
        echo "delay=${delay}" >> "$config_file"
    fi

    # 读取并处理转发目标端口输入
    echo ""
    echo "转发目标端口（对应 cfnat -port，Cloudflare 端口，默认 443）"
    read -p "输入转发目标端口（默认 443）: " tport
    tport=${tport:-443}
    # 更新配置文件中的 tport 参数
    if grep -q "^tport=" "$config_file"; then
        sed -i "s/^tport=.*/tport=${tport}/" "$config_file"
    else
        echo "tport=${tport}" >> "$config_file"
    fi

    # 读取并处理 IP 版本输入
    echo ""
    echo "IP 版本：4=IPv4，6=IPv6（对应 cfnat -ips，默认 4）"
    read -p "输入 IP 版本 4 或 6（默认 4）: " ips
    ips=${ips:-4}
    # 更新配置文件中的 ips 参数
    if grep -q "^ips=" "$config_file"; then
        sed -i "s/^ips=.*/ips=${ips}/" "$config_file"
    else
        echo "ips=${ips}" >> "$config_file"
    fi

    # 读取并处理 GitHub 代理输入
    echo ""
    echo "GitHub 下载代理（如 https://ghproxy.com/ ），需以 / 结尾，留空则直连"
    read -p "输入 GitHub 代理 URL（默认留空直连）: " github_proxy
    # 更新配置文件中的 github_proxy 参数
    if grep -q "^github_proxy=" "$config_file"; then
        sed -i "s|^github_proxy=.*|github_proxy=${github_proxy}|" "$config_file"
    else
        echo "github_proxy=${github_proxy}" >> "$config_file"
    fi

    echo ""
    echo -e "${yellow}高级参数（addr/code/domain/ipnum/num/random/task/tls）请直接编辑 $config_file 调整${re}"
}

# 定时更新 IP 库设置（每天定时自动更新并重启）
config_auto_update(){
    echo -e "${yellow}=== 定时更新 IP 库 ===${re}"
    echo "功能: 每天定时下载 6 源合并 IP 库并重启 cfnat，保持 IP 新鲜"
    if [ -n "$auto_update_hour" ]; then
        local h2=$(printf '%02d' "$auto_update_hour")
        echo -e "当前: ${green}每天 ${h2}:00 执行${re}"
    else
        echo -e "当前: ${red}未启用${re}"
    fi
    echo ""
    read -p "输入每天执行时间（小时 0-23，留空保持不变，输入 x 禁用）: " au
    if [ -z "$au" ]; then
        echo "未修改，保持当前设置"
        return
    fi
    if [ "$au" = "x" ] || [ "$au" = "X" ]; then
        auto_update_hour=""
        echo -e "${yellow}已禁用定时更新${re}"
    elif [[ "$au" =~ ^[0-9]+$ ]] && [ "$au" -ge 0 ] && [ "$au" -le 23 ]; then
        auto_update_hour=$au
        local h2=$(printf '%02d' "$au")
        echo -e "${green}已设置每天 ${h2}:00 自动更新 IP 库${re}"
    else
        echo -e "${red}无效输入（需 0-23 或 x），未修改${re}"
        return
    fi
    # 写入配置文件
    if grep -q "^auto_update_hour=" "$config_file"; then
        sed -i "s/^auto_update_hour=.*/auto_update_hour=${auto_update_hour}/" "$config_file"
    else
        echo "auto_update_hour=${auto_update_hour}" >> "$config_file"
    fi
    # 立即同步 crontab（无需重启 cfnat 即可生效）
    add_cron
    if [ -n "$auto_update_hour" ]; then
        local h2=$(printf '%02d' "$auto_update_hour")
        echo -e "${green}crontab 已更新，每天 ${h2}:00 自动执行${re}"
    else
        echo -e "${yellow}crontab 定时更新任务已移除${re}"
    fi
}

kill_cfnat(){
    if [ "$release" = "OpenWRT" ]; then
        # 查询 ./cfnat 进程并获取其 PID
        cfnatpid=$(pgrep -f "./cfnat -colo")

        # 检查是否找到了 PID
        if [ -n "$cfnatpid" ]; then
            echo "./cfnat 进程正在运行，准备杀死进程..."
            kill "$cfnatpid"
            echo -e "${red}./cfnat 进程已被杀死。${re}"
        else
            echo "./cfnat 进程未在运行。"
        fi
    else
        # 检测 $cfnat_file/cfnat 程序是否正在运行
        if pgrep -x "cfnat" > /dev/null; then
            echo "cfnat 进程正在运行，准备杀死进程..."
            # 如果正在运行，结束该程序
            pkill -x "cfnat"
            echo -e "${red}cfnat 已终止。${re}"
        fi
    fi
}

go_cfnat(){
    if [ "$OneclickInstallation" = "${green}一键安装" ]; then
        install_cfnat
    fi
    check_cfnat
    # P1: Docker 版 cfnat 在运行时，不启动脚本版（避免端口冲突+误杀容器进程）
    if docker_cfnat_running; then
        echo -e "${red}端口 $cfnatport 被 Docker 版 cfnat 占用${re}"
        echo "请先停止 Docker 版: docker stop cfnat"
        return 1
    fi
    # bug A 修复：已运行时先 kill 再启动，避免端口冲突
    if [ "$release" = "OpenWRT" ]; then
        pgrep -f "./cfnat -colo" >/dev/null 2>&1 && kill_cfnat
    else
        pgrep -x "cfnat" >/dev/null 2>&1 && kill_cfnat
    fi
    # setsid + disown 彻底脱离父会话，避免菜单脚本退出时 bash wait4(-1) 挂起等 cfnat
    cd $cfnat_file && (setsid nohup ./cfnat -colo $cfnatcolo -addr "$addr:$cfnatport" -port $tport -delay $cfnatdelay -code $code -domain "$domain" -ipnum $ipnum -ips $ips -num $num -random=$random -task $task -tls=$tls >/dev/null 2>&1 &)
}

# 菜单 10: Docker 部署入口
# 无 Docker 环境 → 提示自行安装；有 Docker → 冲突检测+部署（后续完善）
menu_docker(){
    echo -e "${yellow}=== Docker 部署 ===${re}"
    check_docker_env
    case $? in
        0)
            echo -e "${green}Docker 环境就绪${re}"
            # 严格冲突检测：脚本版 cfnat 在运行则先停止+清 crontab，避免端口冲突
            if [ "$release" = "OpenWRT" ]; then
                pgrep -f "./cfnat -colo" >/dev/null 2>&1 && local script_running=1
            else
                pgrep -x "cfnat" >/dev/null 2>&1 && local script_running=1
            fi
            if [ -n "$script_running" ]; then
                echo -e "${yellow}检测到脚本版 cfnat 运行中，停止以避免端口冲突...${re}"
                kill_cfnat
                delete_cron
                echo -e "${green}脚本版已停止，crontab 保活/定时任务已清理${re}"
            fi
            # TODO: 后续实现生成 docker-compose.yml + 启动容器
            echo -e "${yellow}Docker 部署功能开发中...${re}"
            echo "后续将自动生成 docker-compose.yml 并启动容器"
            ;;
        1)
            echo -e "${red}Docker 环境未安装${re}"
            echo ""
            echo "Docker 部署需要先安装 Docker 及 compose 插件，请自行安装："
            echo ""
            echo -e "${yellow}方式1: 官方一键脚本${re}"
            echo "  curl -fsSL https://get.docker.com | sh"
            echo "  systemctl enable --now docker"
            echo ""
            echo -e "${yellow}方式2: 中国镜像加速（PVE 海外访问受限时推荐）${re}"
            echo "  curl -fsSL https://get.docker.com | bash -s docker --mirror Aliyun"
            echo "  systemctl enable --now docker"
            echo ""
            echo -e "${yellow}方式3: Debian/Ubuntu apt 安装${re}"
            echo "  apt update && apt install -y docker.io docker-compose-plugin"
            echo "  systemctl enable --now docker"
            echo ""
            echo "安装完成后重新运行本脚本，选择菜单 10 继续"
            ;;
        2)
            echo -e "${red}Docker 已安装但服务未运行${re}"
            echo "  systemctl start docker"
            echo "启动后重新选择菜单 10"
            ;;
        3)
            echo -e "${red}缺少 docker compose 插件${re}"
            echo "  apt install -y docker-compose-plugin"
            echo "安装后重新选择菜单 10"
            ;;
    esac
}

state_cfnat(){
    echo -e "${yellow} 系统: ${re}${release}${re}"
    echo -e "${yellow} 架构: ${re}${Architecture}${re}"
    echo -e "${yellow} IP库: ${IPLibrary}${re}"
    echo -e "${yellow} 数据中心: ${re}${cfnatcolo}${re}"
    echo -e "${yellow} 有效延迟: ${re}${cfnatdelay}ms${re}"
    echo -e "${yellow} 目标端口: ${re}${tport}${re}"
    echo -e "${yellow} IP版本: ${re}IPv${ips}${re}"
    # 显示 GitHub 代理状态
    if [ -n "$github_proxy" ]; then
        echo -e "${yellow} GitHub代理: ${re}${github_proxy}${re}"
    else
        echo -e "${yellow} GitHub代理: ${re}直连${re}"
    fi
    echo -e "${yellow} 本地服务: ${re}127.0.0.1:${cfnatport}${re}"
    #echo -e "${yellow} 内网服务: ${re}${lanip}:${cfnatport}${re}"
    # 将lanip转成数组
    IFS=$'\n' read -rd '' -a ip_array <<< "$lanip"

    # 输出结果
    if [ ${#ip_array[@]} -eq 1 ]; then
        echo -e "${yellow} 内网服务: ${re}${ip_array[0]}:$cfnatport${reset}"
    else
        echo -e "${yellow} 内网服务: ${re}${ip_array[0]}:$cfnatport${reset}"
        for i in "${!ip_array[@]}"; do
            if [ $i -ne 0 ]; then
                echo "           ${ip_array[$i]}:$cfnatport"
            fi
        done
    fi
}

site_release(){
    echo -e "${yellow} 设置系统信息...${re}"
    echo -e "${yellow} 1. ${re}alpine"
    echo -e "${yellow} 2. ${re}Centos"
    echo -e "${yellow} 3. ${re}Debian"
    echo -e "${yellow} 4. ${re}Ubuntu"
    echo -e "${yellow} 5. ${re}OpenWRT"
    read -p $'\033[1;91m请输入你的选择（默认 OpenWRT）: \033[0m' choice_release
    # 根据用户选择赋值给 release 变量
    case $choice_release in
        1)
            release="alpine"
            ;;
        2)
            release="Centos"
            ;;
        3)
            release="Debian"
            ;;
        4)
            release="Ubuntu"
            ;;
        5)
            release="OpenWRT"
            ;;
        *)
            release="OpenWRT"  # 默认值
            ;;
    esac
    if grep -q "^release=" "$config_file"; then
        sed -i "s/^release=.*/release=${release}/" "$config_file"
    else
        echo "release=${release}" >> "$config_file"
    fi
    echo "你选择的系统是: $release"
}

site_Architecture(){
    echo -e "${yellow} 设置架构信息...${re}"
    echo -e "${yellow} 1. ${re}termux （安卓termux）"
    echo -e "${yellow} 2. ${re}386 （老古董 32位x86软路由）"
    echo -e "${yellow} 3. ${re}amd64 （64位x86软路由虚拟机）"
    echo -e "${yellow} 4. ${re}arm （32位 老arm机器）"
    echo -e "${yellow} 5. ${re}arm64 （硬路由刷机OpenWRT）"
    echo -e "${yellow} 6. ${re}s390x"
    echo -e "${yellow} 7. ${re}mips"
    echo -e "${yellow} 8. ${re}mips64"
    read -p $'\033[1;91m请输入你的选择（默认 amd64）: \033[0m' choice_Architecture
    # 根据用户选择赋值给 release 变量
    case $choice_Architecture in
        1)
            Architecture="termux"
            ;;
        2)
            Architecture="386"
            ;;
        3)
            Architecture="amd64"
            ;;
        4)
            Architecture="arm"
            ;;
        5)
            Architecture="arm64"
            ;;
        6)
            Architecture="s390x"
            ;;
        7)
            Architecture="mips"
            ;;
        8)
            Architecture="mips64"
            ;;
        *)
            Architecture="amd64"  # 默认值
            ;;
    esac
    if grep -q "^Architecture=" "$config_file"; then
        sed -i "s/^Architecture=.*/Architecture=${Architecture}/" "$config_file"
    else
        echo "Architecture=${Architecture}" >> "$config_file"
    fi
    echo "你选择的架构是: $Architecture"
}
#########################梦开始的地方##############################
#无交互执行
# 子命令模式：crontab 定时更新 IP 库调用
# 用法: bash cfnat.sh --update-ips
if [ "$1" = "--update-ips" ]; then
    check_cfnat
    up_merged
    exit $?
fi

# P0: 保活任务 Docker 感知
# Docker 版 cfnat 在运行时，保活任务（$1=colo参数）不启动脚本版，避免端口冲突
# --update-ips 已在上面 exit，此处只拦截保活任务；交互菜单（$1 为空）不受影响
if [ -n "$1" ] && docker_cfnat_running; then
    exit 0
fi

if [ -n "$1" ]; then
    check_cfnat
    if [ "$OneclickInstallation" = "${green}一键安装" ]; then
        install_cfnat
    fi
    cfnatcolo=${1^^}
    # 检测配置文件是否存在
    if [ -f "$config_file" ]; then
        # 如果存在，读取 colo 字段内容
        colo=$(grep '^colo=' "$config_file" | cut -d'=' -f2)
        if [ $cfnatcolo = $colo ] && [ $statecfnat = "${green}运行中" ]; then
            state_cfnat
            echo -e "${green}cfnat 正在运行...${re}"
            exit
        else
            kill_cfnat
        fi
    fi
    # 更新配置文件中的 colo 参数
    if grep -q "^colo=" "$config_file"; then
        sed -i "s/^colo=.*/colo=${cfnatcolo}/" "$config_file"
    else
        echo "colo=${cfnatcolo}" >> "$config_file"
    fi
    # 保活入口：setsid 脱离，避免 crontab 父进程退出时 wait4(-1) 挂起
    cd $cfnat_file && (setsid nohup ./cfnat -colo $cfnatcolo -addr "$addr:$cfnatport" -port $tport -delay $cfnatdelay -code $code -domain "$domain" -ipnum $ipnum -ips $ips -num $num -random=$random -task $task -tls=$tls >/dev/null 2>&1 &)
    #echo "setsid nohup ./cfnat -colo HKG -port 443 -delay 200 -ips 4 -addr "0.0.0.0:1234" >/dev/null 2>&1 &"
    state_cfnat
    echo -e "${green}cfnat 开始执行...${re}"
else
    while true; do
    check_cfnat
    clear
    echo "cfnat 原作者: https://t.me/CF_NAT/38840 缝合怪: cmliu 定制: yh"
    echo "--------------------------------"
    echo -e "${yellow} 状态: ${InstallationStatus} ${statecfnat} ${re}"
    state_cfnat
    echo "--------------------------------"
    echo -e "${yellow} 1. ${OneclickInstallation}${re}"
    echo "--------------------------------"
    echo -e "${yellow} 2. 启动 cfnat ${re}"
    echo -e "${yellow} 3. 停止 cfnat ${re}"
    echo -e "${yellow} 4. 重启 cfnat ${re}"
    echo -e "${yellow} 5. 配置 cfnat ${ps}${re}"
    echo "--------------------------------"
    echo -e "${yellow} 6. ${green}调试运行 cfnat ${re} ${Androidps}${re}"
    echo -e "${yellow} 7. 手动设置系统架构${re}"
    echo "--------------------------------"
    echo -e "${yellow} 8. 更新 IP 库（6源合并去重）${re}"
    echo -e "${yellow} 9. 定时更新设置（每天 $(printf '%02d' ${auto_update_hour:-4}):00 自动更新+重启）${re}"
    echo "--------------------------------"
    if check_docker_env; then
        echo -e "${yellow}10. Docker 部署 ${re}${green}(Docker环境就绪)${re}"
    else
        echo -e "${yellow}10. Docker 部署 ${re}${red}(Docker环境未安装)${re}"
    fi
    echo "--------------------------------"
    echo -e "\033[0;97m 0. 退出脚本"
    echo -e "${yellow}--------------------------------${re}"
    ps=""
    siteps=""
    # EOF(管道输入耗尽/Ctrl+D)时 read 返回非零，直接退出菜单，避免空读死循环
    read -p $'\033[1;91m请输入你的选择: \033[0m' choice || break
    case $choice in
        1)
            clear
            if [ "$OneclickInstallation" = "${red}一键卸载" ]; then
                uninstall_cfnat
            else
                install_cfnat
            fi
        ;;
        2)
            if [ ! -f "$config_file" ]; then
                config_cfnat
            fi
            go_cfnat
            add_cron
        ;;
        3)
            kill_cfnat
            delete_cron
        ;;
        4)
            kill_cfnat
            go_cfnat
            add_cron
        ;;
        5)
            if [ "$OneclickInstallation" = "${green}一键安装" ]; then
                install_cfnat
            fi
            config_cfnat
            ps="${red}完成配置后需重启cfnat才能生效！"
        ;;
        6)
            if [ "$OneclickInstallation" = "${green}一键安装" ]; then
                install_cfnat
            elif [ $statecfnat = "${green}运行中" ]; then
                kill_cfnat
            fi
            # 前台调试：trap INT 让 Ctrl+C 只终止 cfnat，不连带退出脚本
            # cfnat(SIG_DFL) 收到 SIGINT 停止；bash 捕获后继续返回菜单
            # 不调 delete_cron：保活任务检测到 cfnat 运行中会自动 exit，不干扰调试
            trap 'echo -e "\n${yellow}调试已停止，返回菜单...${re}"' INT
            cd $cfnat_file && ./cfnat -colo $cfnatcolo -addr "$addr:$cfnatport" -port $tport -delay $cfnatdelay -code $code -domain "$domain" -ipnum $ipnum -ips $ips -num $num -random=$random -task $task -tls=$tls
            trap - INT
        ;;
        7)  
            kill_cfnat
            uninstall_cfnat
            mkdir $cfnat_file
            site_release
            site_Architecture
            colo="SJC,LAX,HKG"
            echo "colo=${colo}" >> "$config_file"
            port="1234"
            echo "port=${port}" >> "$config_file"
            echo "addr=" >> "$config_file"
            delay="300"
            echo "delay=${delay}" >> "$config_file"
            echo "tport=" >> "$config_file"
            echo "code=" >> "$config_file"
            echo "domain=" >> "$config_file"
            echo "ipnum=" >> "$config_file"
            echo "ips=" >> "$config_file"
            echo "num=" >> "$config_file"
            echo "random=" >> "$config_file"
            echo "task=" >> "$config_file"
            echo "tls=" >> "$config_file"
            echo "github_proxy=" >> "$config_file"
            auto_update_hour="4"
            echo "auto_update_hour=${auto_update_hour}" >> "$config_file"
            echo -e "${red}设置完成后需卸载重装 cfnat 才能生效！"
            install_cfnat
        ;;
        8)
            up_merged
        ;;
        9)
            config_auto_update
        ;;
        10)
            menu_docker
        ;;
        0)
            clear
            exit
        ;;
        *)
            echo "无效的输入!"
            ps=""
        ;;
    esac
        break_end
    done
fi

# 显式 exit，避免 bash 自然脚本结尾时因后台子进程未 disown 而进入 wait4(-1) 挂起
exit 0
