#!/bin/bash

# JSON Network Interface Status Checker
# Tests for flags.UP, flags.LOWER_UP and operstate: UP

check_interface_status() {
    local json_file="$1"
    local json_string="$2"
    local input_source=""
    
    # Determine input source
    if [[ -n "$json_file" ]]; then
        if [[ ! -f "$json_file" ]]; then
            echo "Error: File '$json_file' not found"
            return 1
        fi
        input_source="$json_file"
        json_data=$(cat "$json_file")
    elif [[ -n "$json_string" ]]; then
        input_source="provided string"
        json_data="$json_string"
    else
        echo "Error: No JSON input provided"
        return 1
    fi
    
    # Check if jq is available
    if ! command -v jq &> /dev/null; then
        echo "Error: jq is required but not installed"
        echo "Please install jq: sudo apt-get install jq (Ubuntu/Debian) or brew install jq (macOS)"
        return 1
    fi
    
    # Validate JSON format
    if ! echo "$json_data" | jq empty 2>/dev/null; then
        echo "Error: Invalid JSON format in $input_source"
        return 1
    fi
    
    echo "Checking interface status from: $input_source"
    echo "========================================"
    
    # Extract interface name for display
    ifname=$(echo "$json_data" | jq -r '.ifname // "unknown"')
    echo "Interface: $ifname"
    echo
    
    # Check for UP flag
    has_up=$(echo "$json_data" | jq -r '.flags | if type == "array" then (. | contains(["UP"])) else false end')
    
    # Check for LOWER_UP flag  
    has_lower_up=$(echo "$json_data" | jq -r '.flags | if type == "array" then (. | contains(["LOWER_UP"])) else false end')
    
    # Check for operstate UP
    operstate=$(echo "$json_data" | jq -r '.operstate // "unknown"')
    has_operstate_up=$([ "$operstate" = "UP" ] && echo "true" || echo "false")
    
    # Display results
    echo "Test Results:"
    echo "-------------"
    printf "%-20s %s\n" "flags.UP:" "$([[ $has_up == "true" ]] && echo "✓ PASS" || echo "✗ FAIL")"
    printf "%-20s %s\n" "flags.LOWER_UP:" "$([[ $has_lower_up == "true" ]] && echo "✓ PASS" || echo "✗ FAIL")"
    printf "%-20s %s\n" "operstate UP:" "$([[ $has_operstate_up == "true" ]] && echo "✓ PASS" || echo "✗ FAIL")"
    echo
    
    # Overall status
    if [[ $has_up == "true" && $has_lower_up == "true" && $has_operstate_up == "true" ]]; then
        echo "Overall Status: ✓ ALL TESTS PASSED - Interface is UP and operational"
        return 0
    else
        echo "Overall Status: ✗ SOME TESTS FAILED - Interface may have issues"
        echo
        echo "Current values:"
        echo "  flags: $(echo "$json_data" | jq -c '.flags')"
        echo "  operstate: $operstate"
        return 1
    fi
}

# Display usage information
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Test JSON network interface data for UP status"
    echo
    echo "Options:"
    echo "  -f, --file FILE     Read JSON from file"
    echo "  -s, --string JSON   Process JSON string directly"
    echo "  -h, --help         Show this help message"
    echo
    echo "Examples:"
    echo "  $0 -f interface.json"
    echo "  $0 -s '{\"ifname\":\"eth0\",\"flags\":[\"UP\",\"LOWER_UP\"],\"operstate\":\"UP\"}'"
    echo "  cat interface.json | $0"
}

# Main execution
main() {
    local json_file=""
    local json_string=""
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -f|--file)
                json_file="$2"
                shift 2
                ;;
            -s|--string)
                json_string="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
    
    # If no arguments provided, try to read from stdin
    if [[ -z "$json_file" && -z "$json_string" ]]; then
        if [[ ! -t 0 ]]; then
            # Data available on stdin
            json_string=$(cat)
        else
            echo "Error: No input provided"
            usage
            exit 1
        fi
    fi
    
    # Run the check
    check_interface_status "$json_file" "$json_string"
    exit $?
}

# Run main function with all arguments
main "$@"