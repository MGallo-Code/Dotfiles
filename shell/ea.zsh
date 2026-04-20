# EA-specific shell commands

# Navigate to EA and open Claude
ea() {
    cd ~/Documents/EA && claude
}

# Navigate to Wiki and open Claude
wiki() {
    cd ~/Documents/Wiki && claude
}

# Navigate to IT Worker and open Claude
it() {
    cd ~/Documents/IT-Worker && claude
}

# Drop into practice workspace with venv active
practice() {
    mkdir -p ~/Documents/EA/exercises/workspace
    if [ ! -d ~/Documents/EA/exercises/.venv ]; then
        echo "Setting up practice environment..."
        python3 -m venv ~/Documents/EA/exercises/.venv
        ~/Documents/EA/exercises/.venv/bin/pip install pytest
        echo "Done!"
    fi
    source ~/Documents/EA/exercises/.venv/bin/activate
    cd ~/Documents/EA/exercises/workspace
    nvim .
}
