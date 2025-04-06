#!/bin/bash

LOG_FILE="/home/pi/install.log"
CONFIG_FILE="/home/pi/tv_config.json"
VIDEO_DIR="/home/pi/videos"

echo "Starting installation..." | tee -a $LOG_FILE

# Ensure required directories exist
mkdir -p "$VIDEO_DIR"

# Install required packages
echo "Installing dependencies..." | tee -a $LOG_FILE
sudo apt update && sudo apt install -y cec-utils vlc wget ssmtp mailutils cron jq || {
    echo "Error installing dependencies!" | tee -a $LOG_FILE
    exit 1
}

# Prompt user for Google Drive File ID
read -p "Enter Google Drive File ID: " FILE_ID
echo "Using File ID: $FILE_ID" | tee -a $LOG_FILE

# Define file paths
TEMP_VIDEO="$VIDEO_DIR/temp_video.mp4"
GDRIVE_URL="https://drive.google.com/uc?id=$FILE_ID&export=download"

# Download the video
echo "Downloading video from Google Drive..." | tee -a $LOG_FILE
wget -O "$TEMP_VIDEO" "$GDRIVE_URL" || {
    echo "Error: Failed to download video! Check the File ID." | tee -a $LOG_FILE
    exit 1
}

# Extract filename from the downloaded video
VIDEO_NAME=$(ls -t "$VIDEO_DIR" | grep -E "\.mp4$" | head -n 1)
VIDEO_FILE="$VIDEO_DIR/$VIDEO_NAME"

# Move temp video to final location
mv "$TEMP_VIDEO" "$VIDEO_FILE"

# Save config file
echo "{\"file_id\": \"$FILE_ID\", \"video_file\": \"$VIDEO_FILE\"}" > "$CONFIG_FILE"

echo "Video downloaded and saved as: $VIDEO_NAME" | tee -a $LOG_FILE

# Create TV control script
echo "Deploying tv_control.sh..." | tee -a $LOG_FILE
cat > /home/pi/tv_control.sh <<'EOF'
#!/bin/bash

LOG_FILE="/home/pi/tv_control.log"
CONFIG_FILE="/home/pi/tv_config.json"
VIDEO_DIR="/home/pi/videos"
EMAIL_TO="your-email@gmail.com"

mkdir -p "$VIDEO_DIR"  # Ensure video directory exists

log_message() { echo "$(date) - $1" | tee -a $LOG_FILE; }
send_email() { echo -e "Subject: TV Control Error\n\n$1" | ssmtp $EMAIL_TO; }

check_tv_status() { 
    TV_STATUS=$(echo "pow 0" | cec-client -s -d 1 | grep "power status:")
    [[ "$TV_STATUS" == *"on"* ]] && log_message "TV is ON." || { log_message "TV failed to turn ON!"; send_email "TV failed to turn ON!"; }
}

HDMI_CONNECTED=$(cec-client -l | grep -q "device: 1" && echo "yes" || echo "no")

turn_on_tv() {
    if [ "$HDMI_CONNECTED" = "yes" ]; then
        echo "on 0" | cec-client -s -d 1
        sleep 5
        check_tv_status
    else
        log_message "No HDMI device detected. Skipping TV power on."
    fi
}

turn_off_tv() {
    if [ "$HDMI_CONNECTED" = "yes" ]; then
        echo "standby 0" | cec-client -s -d 1
        log_message "TV turned off."
    else
        log_message "No HDMI device detected. Skipping TV power off."
    fi
}
download_video() { 
    FILE_ID=$(jq -r '.file_id' $CONFIG_FILE)
    GDRIVE_URL="https://drive.google.com/uc?id=$FILE_ID&export=download"
    TEMP_VIDEO="$VIDEO_DIR/temp_video.mp4"
    wget -O "$TEMP_VIDEO" "$GDRIVE_URL" && {
        VIDEO_NAME=$(ls -t $VIDEO_DIR | grep -E "\.mp4$" | head -n 1)
        VIDEO_FILE="$VIDEO_DIR/$VIDEO_NAME"
        mv "$TEMP_VIDEO" "$VIDEO_FILE"
        jq --arg video_file "$VIDEO_FILE" '.video_file = $video_file' "$CONFIG_FILE" > "/home/pi/tv_config_tmp.json" && mv "/home/pi/tv_config_tmp.json" "$CONFIG_FILE"
        log_message "Video updated."
    } || send_email "Failed to download video!"
}
play_video() {
  cvlc --loop --fullscreen --play-and-exit "$(jq -r '.video_file' $CONFIG_FILE)" > /dev/null 2>&1 &
}
stop_video() {
  pkill vlc
  pkill cvlc
  log_message "Video stopped."
}
setup_cron_jobs() { 
    (crontab -l 2>/dev/null; echo "0 6 * * * /home/pi/tv_control.sh play") | crontab - 
    (crontab -l 2>/dev/null; echo "0 23 * * * /home/pi/tv_control.sh stop") | crontab -
}

case "$1" in
    play) download_video; turn_on_tv; play_video ;;
    stop) stop_video; turn_off_tv ;;
    setup) setup_cron_jobs; log_message "Cron jobs set up." ;;
    *) echo "Usage: $0 {play|stop|setup}"; ;;
esac
EOF

# Make script executable
chmod +x /home/pi/tv_control.sh

# Setup cron jobs
echo "Setting up cron jobs..." | tee -a $LOG_FILE
/home/pi/tv_control.sh setup

# Enable auto-start on boot
echo "@reboot /home/pi/tv_control.sh play" | crontab -

echo "Installation complete!" | tee -a $LOG_FILE
echo "Rebooting in 10 seconds..." | tee -a $LOG_FILE
sleep 10
sudo reboot
