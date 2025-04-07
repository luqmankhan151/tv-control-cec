#!/bin/bash

# Base project directory
USER_HOME=$(eval echo ~"$USER")
PROJECT_DIR="$USER_HOME/tv_project"
VIDEO_DIR="$PROJECT_DIR/videos"
CONFIG_FILE="$PROJECT_DIR/tv_config.json"
INSTALL_LOG_FILE="$PROJECT_DIR/install.log"
CONTROL_SCRIPT="$PROJECT_DIR/tv_control.sh"
LOG_FILE="$PROJECT_DIR/tv_control.log"

# Ensure required directories and log files exist
mkdir -p "$VIDEO_DIR"
touch "$INSTALL_LOG_FILE"
touch "$LOG_FILE"

# Installation log output
echo "Starting installation..." | tee -a "$INSTALL_LOG_FILE"

# Install required dependencies
echo "Installing necessary dependencies..." | tee -a "$INSTALL_LOG_FILE"
sudo apt update && sudo apt install -y cec-utils vlc wget ssmtp mailutils cron jq || {
    echo "Error installing dependencies!" | tee -a "$INSTALL_LOG_FILE"
    exit 1
}

# Prompt for Google Drive File ID
read -p "Enter Google Drive File ID: " FILE_ID

# Ask for device name and email details
while true; do
  read -p "Enter device name (this will be sent in emails): " DEVICE_NAME
  read -p "Enter sender email (used to send messages): " EMAIL_FROM
  read -p "Enter recipient email (where alerts will be sent): " EMAIL_TO
  read -sp "Enter your email app password (for Gmail): " EMAIL_APP_PASSWORD
  echo ""

  # Temporarily configure ssmtp to test email
  echo "Configuring temporary ssmtp to test email..." | tee -a "$INSTALL_LOG_FILE"
  SSMTP_CONF="/etc/ssmtp/ssmtp.conf"
  sudo tee "$SSMTP_CONF" > /dev/null <<EOF
root=$EMAIL_FROM
mailhub=smtp.gmail.com:587
AuthUser=$EMAIL_FROM
AuthPass=$EMAIL_APP_PASSWORD
UseSTARTTLS=YES
UseTLS=YES
hostname=$(hostname)
EOF
  sudo chmod 600 "$SSMTP_CONF"

  # Generate a temporary device ID for testing email
  TEST_DEVICE_ID=$(uuidgen)
  echo -e "Subject: [$TEST_DEVICE_ID] Email Verification\n\nThis is a test message to verify email delivery during setup.\n\nIf you received this, email is working correctly." | ssmtp "$EMAIL_TO"

  echo "A verification email has been sent to $EMAIL_TO."
  read -p "Did you receive the email? (yes/no): " EMAIL_CONFIRM

  if [[ "$EMAIL_CONFIRM" == "yes" ]]; then
    echo "Email verified. Continuing setup..." | tee -a "$INSTALL_LOG_FILE"
    break
  else
    echo "Please check your email details and try again." | tee -a "$INSTALL_LOG_FILE"
  fi
done

# Generate real device ID
DEVICE_ID=$(uuidgen)
echo "Generated Device ID: $DEVICE_ID" | tee -a "$INSTALL_LOG_FILE"
echo "⚠️  Please save this Device ID securely: $DEVICE_ID"

# Download video
TEMP_VIDEO="$VIDEO_DIR/temp_video.mp4"
GDRIVE_URL="https://drive.google.com/uc?id=$FILE_ID&export=download"

echo "Downloading video..." | tee -a "$INSTALL_LOG_FILE"
wget -O "$TEMP_VIDEO" "$GDRIVE_URL" || {
    echo "Error downloading video!" | tee -a "$INSTALL_LOG_FILE"
    exit 1
}

# Rename and move video
VIDEO_NAME="video_$(date +%s).mp4"
VIDEO_FILE="$VIDEO_DIR/$VIDEO_NAME"
mv "$TEMP_VIDEO" "$VIDEO_FILE"

# Write JSON config safely
TMP_JSON=$(mktemp)
cat > "$TMP_JSON" <<EOF
{
  "file_id": "$FILE_ID",
  "video_file": "$VIDEO_FILE",
  "device_id": "$DEVICE_ID",
  "device_name": "$DEVICE_NAME",
  "email_to": "$EMAIL_TO",
  "email_from": "$EMAIL_FROM"
}
EOF
mv "$TMP_JSON" "$CONFIG_FILE"

# Validate JSON
if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
  echo "Invalid JSON format in $CONFIG_FILE"
  cat "$CONFIG_FILE"
  exit 1
fi

echo "Saving control script..." | tee -a "$INSTALL_LOG_FILE"
cat > "$CONTROL_SCRIPT" <<'EOF'
#!/bin/bash

PROJECT_DIR="$(dirname "$(readlink -f "$0")")"
CONFIG_FILE="$PROJECT_DIR/tv_config.json"
VIDEO_DIR="$PROJECT_DIR/videos"
LOG_FILE="$PROJECT_DIR/tv_control.log"

EMAIL_TO=$(jq -r '.email_to' "$CONFIG_FILE")
EMAIL_FROM=$(jq -r '.email_from' "$CONFIG_FILE")
DEVICE_ID=$(jq -r '.device_id' "$CONFIG_FILE")
DEVICE_NAME=$(jq -r '.device_name' "$CONFIG_FILE")

log() { echo "$(date): $1" | tee -a "$LOG_FILE"; }
send_email() { echo -e "Subject: [$DEVICE_NAME - $DEVICE_ID] TV Control Error\n\n$1" | ssmtp "$EMAIL_TO"; }

check_tv_status() {
  TV_STATUS=$(echo "pow 0" | cec-client -s -d 1 | grep "power status:")
  [[ "$TV_STATUS" == *"on"* ]] && log "TV is ON." || {
    log "TV failed to turn ON!"
    send_email "TV failed to turn ON!"
  }
}

HDMI_CONNECTED=$(cec-client -l | grep -q "device: 1" && echo "yes" || echo "no")

turn_on_tv() {
  if [ "$HDMI_CONNECTED" = "yes" ]; then
    echo "on 0" | cec-client -s -d 1
    sleep 5
    check_tv_status
  else
    log "No HDMI device detected. Skipping TV power on."
  fi
}

turn_off_tv() {
  if [ "$HDMI_CONNECTED" = "yes" ]; then
    echo "standby 0" | cec-client -s -d 1
    log "TV turned off."
  else
    log "No HDMI device detected. Skipping TV power off."
  fi
}

download_video() {
  FILE_ID=$(jq -r '.file_id' "$CONFIG_FILE")
  GDRIVE_URL="https://drive.google.com/uc?id=$FILE_ID&export=download"
  TEMP_VIDEO="$VIDEO_DIR/temp_video.mp4"
  wget -O "$TEMP_VIDEO" "$GDRIVE_URL" && {
    VIDEO_NAME="video_$(date +%s).mp4"
    VIDEO_FILE="$VIDEO_DIR/$VIDEO_NAME"
    mv "$TEMP_VIDEO" "$VIDEO_FILE"
    jq --arg video_file "$VIDEO_FILE" '.video_file = $video_file' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    log "Video updated."
  } || send_email "Failed to download video!"
}

play_video() {
  cvlc --loop --fullscreen --play-and-exit "$(jq -r '.video_file' "$CONFIG_FILE")" > /dev/null 2>&1 &
  log "Video started."
}

stop_video() {
  pkill vlc
  pkill cvlc
  log "Video stopped."
}

setup_cron_jobs() {
  # Ensure correct PATH for cron jobs and full path to script
  echo "Setting up cron jobs..." | tee -a "$LOG_FILE"

  # Full path to CONTROL_SCRIPT (ensure it is correct)
  CONTROL_SCRIPT="/home/luqman/tv_project/tv_control.sh"

  # Update the cron job with full path to the script and argument (play/stop)
  (crontab -l 2>/dev/null | grep -v "$CONTROL_SCRIPT play"; echo "0 6 * * * /bin/bash $CONTROL_SCRIPT play >> /home/luqman/tv_project/tv_control.log 2>&1") | crontab -
  (crontab -l 2>/dev/null | grep -v "$CONTROL_SCRIPT stop"; echo "0 23 * * * /bin/bash $CONTROL_SCRIPT stop >> /home/luqman/tv_project/tv_control.log 2>&1") | crontab -
}


case "$1" in
  play) download_video; turn_on_tv; play_video ;;
  stop) stop_video; turn_off_tv ;;
  setup) setup_cron_jobs; log "Cron jobs set up." ;;
  *) echo "Usage: $0 {play|stop|setup}" ;;
esac
EOF

chmod +x "$CONTROL_SCRIPT"

# Setup cron jobs (ensuring no duplicates)
"$CONTROL_SCRIPT" setup

echo "Installation complete! Device ID: $DEVICE_ID and Device Name: $DEVICE_NAME" | tee -a "$INSTALL_LOG_FILE"
