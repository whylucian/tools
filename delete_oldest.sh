#!/bin/bash                                                               
                                                                          
# delete_oldest.sh - Delete oldest files until specified amount is deleted
                                                                          
set -euo pipefail                                                         
                                                                          
# Function to display usage                                               
usage() {                                                                 
    echo "Usage: $0 <size>"                                               
    echo "  size: Amount to delete (e.g., 10G, 20M, 1.2T, 500K)"          
    echo "  Supported units: K, M, G, T (case insensitive)"               
    exit 1                                                                
}                                                                         
                                                                          
# Function to convert human readable size to bytes                        
size_to_bytes() {                                                         
    local size="$1"                                                       
    local number unit                                                     
                                                                          
    # Extract number and unit                                             
    if [[ $size =~ ^([0-9]*\.?[0-9]+)([KkMmGgTt]?)$ ]]; then              
        number="${BASH_REMATCH[1]}"                                       
        unit="${BASH_REMATCH[2]}"                                         
    else                                                                  
        echo "Error: Invalid size format '$size'" >&2                     
        return 1                                                          
    fi                                                                    
                                                                          
    # Convert to bytes                                                    
    case "${unit,,}" in  # ${unit,,} converts to lowercase                
        ""|"b") echo "${number%.*}" ;;  # Remove decimal part for bytes   
        "k") echo "$(echo "$number * 1024" | bc)" | cut -d'.' -f1 ;;      
        "m") echo "$(echo "$number * 1024 * 1024" | bc)" | cut -d'.' -f1 ;;
        "g") echo "$(echo "$number * 1024 * 1024 * 1024" | bc)" | cut -d'.
  ' -f1 ;;                                                                    
        "t") echo "$(echo "$number * 1024 * 1024 * 1024 * 1024" | bc)" |  
  cut -d'.' -f1 ;;                                                            
        *) echo "Error: Unknown unit '$unit'" >&2; return 1 ;;            
    esac                                                                  
}                                                                         
                                                                          
# Function to format bytes for human readable output                      
bytes_to_human() {                                                        
    local bytes=$1                                                        
    if (( bytes >= 1024**4 )); then                                       
        echo "$(echo "scale=1; $bytes / (1024^4)" | bc)T"                 
    elif (( bytes >= 1024**3 )); then                                     
        echo "$(echo "scale=1; $bytes / (1024^3)" | bc)G"                 
    elif (( bytes >= 1024**2 )); then                                     
        echo "$(echo "scale=1; $bytes / (1024^2)" | bc)M"                 
    elif (( bytes >= 1024 )); then                                        
        echo "$(echo "scale=1; $bytes / 1024" | bc)K"                     
    else                                                                  
        echo "${bytes}B"                                                  
    fi                                                                    
}                                                                         
                                                                          
# Check arguments                                                         
if [[ $# -ne 1 ]]; then                                                   
    usage                                                                 
fi                                                                        
                                                                          
target_size="$1"                                                          
                                                                          
# Check if bc is available (needed for floating point arithmetic)         
if ! command -v bc >/dev/null 2>&1; then                                  
    echo "Error: 'bc' command is required but not installed" >&2          
    exit 1                                                                
fi                                                                        
                                                                          
# Convert target size to bytes                                            
target_bytes=$(size_to_bytes "$target_size")                              
if [[ $? -ne 0 ]]; then                                                   
    usage                                                                 
fi                                                                        
                                                                          
echo "Target deletion size: $(bytes_to_human $target_bytes)"              
echo "Finding oldest files..."                                            
                                                                          
# Find all files, sort by modification time (oldest first)                
# Using a temporary file to avoid argument list too long                  
temp_file=$(mktemp)                                                       
trap "rm -f '$temp_file'" EXIT                                            
                                                                          
# Find files and sort by modification time (oldest first)                 
# Format: size filename                                                   
find . -type f -exec stat -c "%Y %s %n" {} \; | sort -n | cut -d' ' -f2- >
  "$temp_file"                                                                
                                                                          
deleted_bytes=0                                                           
deleted_count=0                                                           
                                                                          
echo "Starting deletion..."                                               
                                                                          
while IFS=' ' read -r size filename && (( deleted_bytes < target_bytes ));
  do                                                                          
    # Skip if file doesn't exist (might have been deleted by another      
  process)                                                                    
    if [[ ! -f "$filename" ]]; then                                       
        continue                                                          
    fi                                                                    
                                                                          
    # Delete the file                                                     
    if rm "$filename" 2>/dev/null; then                                   
        deleted_bytes=$((deleted_bytes + size))                           
        deleted_count=$((deleted_count + 1))                              
                                                                          
        echo "Deleted: $filename ($(bytes_to_human $size))"               
                                                                          
        # Progress update every 100 files                                 
        if (( deleted_count % 100 == 0 )); then                           
            echo "Progress: Deleted $deleted_count files, $(bytes_to_human
  $deleted_bytes) total"                                                      
        fi                                                                
    else                                                                  
        echo "Warning: Could not delete $filename" >&2                    
    fi                                                                    
done < "$temp_file"                                                       
                                                                          
echo "Deletion complete!"                                                 
echo "Files deleted: $deleted_count"                                      
echo "Total size deleted: $(bytes_to_human $deleted_bytes)"               
echo "Target was: $(bytes_to_human $target_bytes)"                        
                                                                          
if (( deleted_bytes >= target_bytes )); then                              
    echo "✓ Target deletion size reached"                                 
else                                                                      
    echo "⚠ Warning: Target size not reached (no more files to delete)"   
fi                                          
