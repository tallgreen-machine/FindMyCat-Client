# Use Ubuntu with Swift pre-installed
FROM swift:5.9

# Install essential tools
RUN apt-get update && apt-get install -y \
    curl \
    git \
    vim \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /workspace

# Copy your Swift files
COPY . .

# Make sure we can build
RUN swift --version