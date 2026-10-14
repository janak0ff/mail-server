#!/bin/bash
# Zimbra Password Reset Tool with Manual Password Option

# Generate random 12-character password (letters and numbers only)
generate_password() {
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12
}

echo "========================================"
echo "Zimbra's Password Reset Tool"
echo "========================================"
read -p "Enter user email: " USER_EMAIL

# Check if user exists
if ! zmprov -l ga "$USER_EMAIL" &>/dev/null; then
    echo "ERROR: User '$USER_EMAIL' does not exist"
    exit 1
fi

# Password options
echo ""
echo "Password options:"
echo "  1) Auto-generate password (default)"
echo "  2) Enter password manually"
read -p "Choose (1 or 2): " PASS_CHOICE

# Set password based on user choice
if [[ "$PASS_CHOICE" == "2" ]]; then
    echo ""
    read -p "Enter new password: " NEW_PASSWORD
    echo ""
    
    # Check if password is empty
    if [[ -z "$NEW_PASSWORD" ]]; then
        echo "No password entered. Using auto-generated password..."
        NEW_PASSWORD=$(generate_password)
    fi
else
    # Auto-generate password (default)
    NEW_PASSWORD=$(generate_password)
fi

# Ask if user must change password on next login
echo ""
read -p "Must change password on next login? (y/n): " FORCE_CHANGE

# Reset password
if zmprov -l sp "$USER_EMAIL" "$NEW_PASSWORD"; then
    # Set force change flag based on user input
    if [[ "$FORCE_CHANGE" == "y" || "$FORCE_CHANGE" == "Y" ]]; then
        zmprov -l ma "$USER_EMAIL" zimbraPasswordMustChange TRUE
        STATUS="Must change on next login"
    else
        zmprov -l ma "$USER_EMAIL" zimbraPasswordMustChange FALSE
        STATUS="Can login with current password"
    fi
    
    echo ""
    echo "========================================"
    echo "SUCCESS"
    echo "========================================"
    echo "Email:    $USER_EMAIL"
    echo "Password: $NEW_PASSWORD"
    echo "Status:   $STATUS"
    echo "========================================"
else
    echo "ERROR: Failed to reset password for $USER_EMAIL"
    exit 1
fi