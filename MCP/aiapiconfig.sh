#!/usr/bin/env bash
#
# AI API Configuration & Connectivity Test
#

set -e

CONFIG_DIR="${HOME}/.config/ai-api"
CONFIG_FILE="${CONFIG_DIR}/config.json"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[FAIL]${NC} $1"; }

# Ensure config directory exists
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

print_banner() {
    echo ""
    echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}${BOLD}         AI API Configuration & Test Tool${NC}"
    echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${GREEN}1)${NC} Test Connectivity (all APIs)"
    echo -e "  ${CYAN}2)${NC} Configure Claude API (Anthropic)"
    echo -e "  ${CYAN}3)${NC} Configure OpenAI API (ChatGPT)"
    echo -e "  ${CYAN}4)${NC} Configure Oracle GenAI"
    echo -e "  ${YELLOW}5)${NC} View Current Configuration"
    echo -e "  ${RED}6)${NC} Clear Configuration"
    echo -e "  ${BOLD}0)${NC} Exit"
    echo ""
}

print_prompt() {
    echo ""
    echo -e "[${GREEN}1${NC}:Test ${CYAN}2${NC}:Claude ${CYAN}3${NC}:OpenAI ${CYAN}4${NC}:Oracle ${YELLOW}5${NC}:View ${RED}6${NC}:Clear ${BOLD}0${NC}:Exit]"
}

# Test network connectivity to API endpoints
test_connectivity() {
    echo ""
    echo -e "${BOLD}=== API Endpoint Connectivity Test ===${NC}"
    echo ""
    
    # Claude API
    echo -n "Claude API (api.anthropic.com)... "
    if curl -s --connect-timeout 5 -o /dev/null -w "%{http_code}" https://api.anthropic.com/v1/messages 2>/dev/null | grep -q "401\|403\|400"; then
        log_info "Reachable"
    elif curl -s --connect-timeout 5 https://api.anthropic.com >/dev/null 2>&1; then
        log_info "Reachable"
    else
        log_error "Unreachable"
    fi
    
    # OpenAI API
    echo -n "OpenAI API (api.openai.com)... "
    if curl -s --connect-timeout 5 -o /dev/null -w "%{http_code}" https://api.openai.com/v1/models 2>/dev/null | grep -q "401\|403\|400"; then
        log_info "Reachable"
    elif curl -s --connect-timeout 5 https://api.openai.com >/dev/null 2>&1; then
        log_info "Reachable"
    else
        log_error "Unreachable"
    fi
    
    # Oracle GenAI
    echo -n "Oracle GenAI (generativeai.aiservice.*.oci.oraclecloud.com)... "
    # Try multiple regions
    ORACLE_REACHABLE=false
    for region in us-chicago-1 us-ashburn-1 uk-london-1 eu-frankfurt-1; do
        if curl -s --connect-timeout 5 "https://inference.generativeai.${region}.oci.oraclecloud.com" >/dev/null 2>&1; then
            ORACLE_REACHABLE=true
            log_info "Reachable ($region)"
            break
        fi
    done
    if [[ "$ORACLE_REACHABLE" == "false" ]]; then
        log_error "Unreachable (checked multiple regions)"
    fi
    
    # Oracle Chat
    echo -n "Oracle Chat (chat.oracle.com)... "
    if curl -s --connect-timeout 5 https://chat.oracle.com >/dev/null 2>&1; then
        log_info "Reachable"
    else
        log_error "Unreachable"
    fi
    
    echo ""
    echo -e "${BOLD}=== API Authentication Test ===${NC}"
    echo ""
    
    # Test Claude if configured
    if [[ -f "$CONFIG_FILE" ]] && grep -q "anthropic_api_key" "$CONFIG_FILE" 2>/dev/null; then
        echo -n "Claude API auth... "
        CLAUDE_KEY=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('anthropic_api_key',''))" 2>/dev/null)
        if [[ -n "$CLAUDE_KEY" ]]; then
            RESPONSE=$(curl -s --connect-timeout 10 -X POST https://api.anthropic.com/v1/messages \
                -H "Content-Type: application/json" \
                -H "x-api-key: $CLAUDE_KEY" \
                -H "anthropic-version: 2023-06-01" \
                -d '{"model":"claude-sonnet-4-20250514","max_tokens":10,"messages":[{"role":"user","content":"hi"}]}' 2>/dev/null)
            if echo "$RESPONSE" | grep -q '"content"'; then
                log_info "Authenticated"
            elif echo "$RESPONSE" | grep -q "invalid_api_key\|authentication_error"; then
                log_error "Invalid API key"
            else
                log_warn "Unknown response: $(echo "$RESPONSE" | head -c 100)"
            fi
        fi
    else
        echo "Claude API auth... (not configured)"
    fi
    
    # Test OpenAI if configured
    if [[ -f "$CONFIG_FILE" ]] && grep -q "openai_api_key" "$CONFIG_FILE" 2>/dev/null; then
        echo -n "OpenAI API auth... "
        OPENAI_KEY=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('openai_api_key',''))" 2>/dev/null)
        if [[ -n "$OPENAI_KEY" ]]; then
            RESPONSE=$(curl -s --connect-timeout 10 https://api.openai.com/v1/models \
                -H "Authorization: Bearer $OPENAI_KEY" 2>/dev/null)
            if echo "$RESPONSE" | grep -q '"data"'; then
                log_info "Authenticated"
            elif echo "$RESPONSE" | grep -q "invalid_api_key\|Incorrect API key"; then
                log_error "Invalid API key"
            else
                log_warn "Unknown response: $(echo "$RESPONSE" | head -c 100)"
            fi
        fi
    else
        echo "OpenAI API auth... (not configured)"
    fi
    
    # Test Oracle GenAI if configured
    if [[ -f "$CONFIG_FILE" ]] && grep -q "oracle_compartment_id" "$CONFIG_FILE" 2>/dev/null; then
        echo -n "Oracle GenAI auth... "
        if command -v oci &>/dev/null; then
            COMPARTMENT=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('oracle_compartment_id',''))" 2>/dev/null)
            REGION=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('oracle_region','us-chicago-1'))" 2>/dev/null)
            if [[ -n "$COMPARTMENT" ]]; then
                RESPONSE=$(oci generative-ai model list --compartment-id "$COMPARTMENT" --region "$REGION" 2>&1)
                if echo "$RESPONSE" | grep -q '"data"'; then
                    log_info "Authenticated"
                elif echo "$RESPONSE" | grep -q "NotAuthenticated\|401"; then
                    log_error "Auth failed (check OCI config)"
                else
                    log_warn "Response: $(echo "$RESPONSE" | head -c 100)"
                fi
            fi
        else
            log_warn "OCI CLI not installed"
        fi
    else
        echo "Oracle GenAI auth... (not configured)"
    fi
}

# Configure Claude API
configure_claude() {
    echo ""
    echo -e "${BOLD}=== Configure Claude API (Anthropic) ===${NC}"
    echo ""
    echo "Get your API key from: https://console.anthropic.com/settings/keys"
    echo ""
    
    read -p "Enter Claude API key (sk-ant-...): " -s api_key
    echo ""
    
    if [[ -z "$api_key" ]]; then
        log_warn "No key entered, cancelled"
        return
    fi
    
    if [[ ! "$api_key" =~ ^sk-ant- ]]; then
        log_warn "Key doesn't look like a Claude API key (should start with sk-ant-)"
        read -p "Continue anyway? (y/n): " confirm
        [[ "$confirm" != "y" ]] && return
    fi
    
    # Test the key
    echo -n "Testing key... "
    RESPONSE=$(curl -s --connect-timeout 10 -X POST https://api.anthropic.com/v1/messages \
        -H "Content-Type: application/json" \
        -H "x-api-key: $api_key" \
        -H "anthropic-version: 2023-06-01" \
        -d '{"model":"claude-sonnet-4-20250514","max_tokens":10,"messages":[{"role":"user","content":"hi"}]}' 2>/dev/null)
    
    if echo "$RESPONSE" | grep -q '"content"'; then
        log_info "Key valid"
        
        # Save to config
        if [[ -f "$CONFIG_FILE" ]]; then
            python3 -c "
import json
c = json.load(open('$CONFIG_FILE'))
c['anthropic_api_key'] = '$api_key'
c['default_provider'] = c.get('default_provider', 'anthropic')
json.dump(c, open('$CONFIG_FILE', 'w'), indent=2)
"
        else
            echo "{\"anthropic_api_key\": \"$api_key\", \"default_provider\": \"anthropic\"}" > "$CONFIG_FILE"
        fi
        chmod 600 "$CONFIG_FILE"
        log_info "Configuration saved"
    else
        log_error "Key invalid or API error"
        echo "Response: $(echo "$RESPONSE" | head -c 200)"
    fi
}

# Configure OpenAI API
configure_openai() {
    echo ""
    echo -e "${BOLD}=== Configure OpenAI API (ChatGPT) ===${NC}"
    echo ""
    echo "Get your API key from: https://platform.openai.com/api-keys"
    echo ""
    
    read -p "Enter OpenAI API key (sk-...): " -s api_key
    echo ""
    
    if [[ -z "$api_key" ]]; then
        log_warn "No key entered, cancelled"
        return
    fi
    
    # Test the key
    echo -n "Testing key... "
    RESPONSE=$(curl -s --connect-timeout 10 https://api.openai.com/v1/models \
        -H "Authorization: Bearer $api_key" 2>/dev/null)
    
    if echo "$RESPONSE" | grep -q '"data"'; then
        log_info "Key valid"
        
        # Save to config
        if [[ -f "$CONFIG_FILE" ]]; then
            python3 -c "
import json
c = json.load(open('$CONFIG_FILE'))
c['openai_api_key'] = '$api_key'
json.dump(c, open('$CONFIG_FILE', 'w'), indent=2)
"
        else
            echo "{\"openai_api_key\": \"$api_key\"}" > "$CONFIG_FILE"
        fi
        chmod 600 "$CONFIG_FILE"
        log_info "Configuration saved"
    else
        log_error "Key invalid or API error"
        echo "Response: $(echo "$RESPONSE" | head -c 200)"
    fi
}

# Configure Oracle GenAI
configure_oracle() {
    echo ""
    echo -e "${BOLD}=== Configure Oracle GenAI ===${NC}"
    echo ""
    echo "Oracle GenAI uses OCI authentication (config file or instance principal)"
    echo ""
    
    # Check OCI CLI
    if ! command -v oci &>/dev/null; then
        log_error "OCI CLI not installed"
        return
    fi
    
    # Check OCI config
    echo -n "Checking OCI config... "
    if oci iam region list --output table &>/dev/null; then
        log_info "OCI CLI configured"
    else
        log_error "OCI CLI not configured properly"
        echo "Run: oci setup config"
        return
    fi
    
    echo ""
    echo "Available regions with GenAI:"
    echo "  1) us-chicago-1 (recommended)"
    echo "  2) us-ashburn-1"
    echo "  3) uk-london-1"
    echo "  4) eu-frankfurt-1"
    echo "  5) ap-osaka-1"
    echo ""
    read -p "Select region [1]: " region_choice
    
    case "${region_choice:-1}" in
        1) REGION="us-chicago-1" ;;
        2) REGION="us-ashburn-1" ;;
        3) REGION="uk-london-1" ;;
        4) REGION="eu-frankfurt-1" ;;
        5) REGION="ap-osaka-1" ;;
        *) REGION="us-chicago-1" ;;
    esac
    
    echo ""
    read -p "Enter compartment OCID: " compartment_id
    
    if [[ -z "$compartment_id" ]]; then
        log_warn "No compartment entered, cancelled"
        return
    fi
    
    # Test access
    echo -n "Testing GenAI access... "
    RESPONSE=$(oci generative-ai model list --compartment-id "$compartment_id" --region "$REGION" 2>&1)
    
    if echo "$RESPONSE" | grep -q '"data"'; then
        log_info "Access confirmed"
        
        # Save to config
        if [[ -f "$CONFIG_FILE" ]]; then
            python3 -c "
import json
c = json.load(open('$CONFIG_FILE'))
c['oracle_compartment_id'] = '$compartment_id'
c['oracle_region'] = '$REGION'
json.dump(c, open('$CONFIG_FILE', 'w'), indent=2)
"
        else
            echo "{\"oracle_compartment_id\": \"$compartment_id\", \"oracle_region\": \"$REGION\"}" > "$CONFIG_FILE"
        fi
        chmod 600 "$CONFIG_FILE"
        log_info "Configuration saved"
        
        # List available models
        echo ""
        echo "Available models:"
        oci generative-ai model list --compartment-id "$compartment_id" --region "$REGION" \
            --query "data[*].{name:\"display-name\",id:id}" --output table 2>/dev/null | head -20
    else
        log_error "Access denied or error"
        echo "Response: $(echo "$RESPONSE" | head -c 200)"
    fi
}

# View configuration
view_config() {
    echo ""
    echo -e "${BOLD}=== Current Configuration ===${NC}"
    echo ""
    echo "Config file: $CONFIG_FILE"
    echo ""
    
    if [[ -f "$CONFIG_FILE" ]]; then
        python3 -c "
import json
c = json.load(open('$CONFIG_FILE'))
for k, v in c.items():
    if 'key' in k.lower():
        print(f'  {k}: {v[:10]}...{v[-4:]}')
    else:
        print(f'  {k}: {v}')
" 2>/dev/null || cat "$CONFIG_FILE"
    else
        echo "  (not configured)"
    fi
}

# Clear configuration
clear_config() {
    echo ""
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_warn "No configuration to clear"
        return
    fi
    
    read -p "Clear all API configuration? (yes/no): " confirm
    if [[ "$confirm" == "yes" ]]; then
        rm -f "$CONFIG_FILE"
        log_info "Configuration cleared"
    else
        log_info "Cancelled"
    fi
}

# Send a test message
send_test_message() {
    echo ""
    echo -e "${BOLD}=== Send Test Message ===${NC}"
    echo ""
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_warn "No API configured"
        return
    fi
    
    echo "Select provider:"
    echo "  1) Claude (Anthropic)"
    echo "  2) OpenAI (ChatGPT)"
    echo "  3) Oracle GenAI"
    read -p "> " provider
    
    read -p "Enter test message: " message
    [[ -z "$message" ]] && message="Hello, respond with one word."
    
    case $provider in
        1)
            CLAUDE_KEY=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('anthropic_api_key',''))" 2>/dev/null)
            if [[ -z "$CLAUDE_KEY" ]]; then
                log_error "Claude not configured"
                return
            fi
            echo ""
            echo "Response:"
            curl -s -X POST https://api.anthropic.com/v1/messages \
                -H "Content-Type: application/json" \
                -H "x-api-key: $CLAUDE_KEY" \
                -H "anthropic-version: 2023-06-01" \
                -d "{\"model\":\"claude-sonnet-4-20250514\",\"max_tokens\":100,\"messages\":[{\"role\":\"user\",\"content\":\"$message\"}]}" | \
                python3 -c "import sys,json; r=json.load(sys.stdin); print(r.get('content',[{}])[0].get('text','Error: '+str(r)))"
            ;;
        2)
            OPENAI_KEY=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('openai_api_key',''))" 2>/dev/null)
            if [[ -z "$OPENAI_KEY" ]]; then
                log_error "OpenAI not configured"
                return
            fi
            echo ""
            echo "Response:"
            curl -s -X POST https://api.openai.com/v1/chat/completions \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer $OPENAI_KEY" \
                -d "{\"model\":\"gpt-4o\",\"max_tokens\":100,\"messages\":[{\"role\":\"user\",\"content\":\"$message\"}]}" | \
                python3 -c "import sys,json; r=json.load(sys.stdin); print(r.get('choices',[{}])[0].get('message',{}).get('content','Error: '+str(r)))"
            ;;
        3)
            COMPARTMENT=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('oracle_compartment_id',''))" 2>/dev/null)
            REGION=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('oracle_region','us-chicago-1'))" 2>/dev/null)
            if [[ -z "$COMPARTMENT" ]]; then
                log_error "Oracle GenAI not configured"
                return
            fi
            echo ""
            echo "Response:"
            oci generative-ai-inference chat --region "$REGION" \
                --compartment-id "$COMPARTMENT" \
                --chat-request "{\"apiFormat\":\"COHERE\",\"message\":\"$message\",\"maxTokens\":100}" \
                --serving-mode "{\"servingType\":\"ON_DEMAND\",\"modelId\":\"cohere.command-r-plus\"}" \
                --query "data.text" --raw-output 2>/dev/null || log_error "Failed to send message"
            ;;
        *)
            log_warn "Invalid selection"
            ;;
    esac
}

main() {
    print_banner
    
    while true; do
        read -p "> " choice
        case $choice in
            1) test_connectivity ;;
            2) configure_claude ;;
            3) configure_openai ;;
            4) configure_oracle ;;
            5) view_config ;;
            6) clear_config ;;
            7) send_test_message ;;  # Hidden option
            0|q|exit) echo "Bye!" && exit 0 ;;
            *) echo "Invalid. [1:Test 2:Claude 3:OpenAI 4:Oracle 5:View 6:Clear 0:Exit]" ;;
        esac
        print_prompt
    done
}

main