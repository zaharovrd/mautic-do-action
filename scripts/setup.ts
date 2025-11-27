#!/usr/bin/env -S deno run --allow-all

/**
 * scripts/setup.ts
 * Main Mautic Docker Compose Setup Script
 * 
 * This is the entry point that orchestrates the entire deployment process
 * using modular TypeScript components for better maintainability.
 */

import { Logger } from './logger.ts';
import { ProcessManager } from './process-manager.ts';
import { DockerManager } from './docker-manager.ts';
import { MauticDeployer } from './mautic-deployer.ts';
import { SSLManager } from './ssl-manager.ts';
import { loadDeploymentConfig } from './config.ts';

async function main() {
  try {
    // Start with immediate console output before logger init
    console.log('🚀 Mautic setup binary starting...');
    console.log(`Timestamp: ${new Date().toISOString()}`);
    console.log(`Deno version: ${Deno.version.deno}`);
    console.log(`Platform: ${Deno.build.os}-${Deno.build.arch}`);

    Logger.log('Starting Mautic Docker Compose setup...', '🚀');
    Logger.log(`Timestamp: ${new Date().toISOString()}`);

    // Initialize logging
    await Logger.init();

    // Wait for VPS initialization
    Logger.log('Waiting for VPS initialization to complete...', '⏳');
    await new Promise(resolve => setTimeout(resolve, 30000));

    // Environment check
    Logger.log('Environment check:', '🔍');
    const user = await ProcessManager.runShell('whoami');
    const pwd = await ProcessManager.runShell('pwd');
    const dockerVersion = await ProcessManager.runShell('docker --version', { ignoreError: true });

    // Memory check
    const memoryInfo = await ProcessManager.runShell('free -h', { ignoreError: true });
    const swapInfo = await ProcessManager.runShell('swapon --show', { ignoreError: true });

    Logger.log(`  - Current user: ${user.output}`);
    Logger.log(`  - Current directory: ${pwd.output}`);
    Logger.log(`  - Docker version: ${dockerVersion.output || 'Not available'}`);
    Logger.log(`  - Memory status: ${memoryInfo.output || 'Not available'}`);
    Logger.log(`  - Swap status: ${swapInfo.output || 'No swap active'}`);

    Logger.log('Setting up memory-conservative environment for installation...', '💾');
    // Load configuration
    Logger.log('Loading deployment configuration...', '📋');
    const config = await loadDeploymentConfig();
    Logger.success('Configuration loaded and validated');

    // ====================== БЛОК ДЛЯ ДИАГНОСТИКИ ======================
    Logger.log('--- STARTING DIAGNOSTICS ---', '🔬');
    Logger.log(`Value of config.mauticPlugins: "${config.mauticPlugins}"`, '🔬');
    Logger.log(`Type of config.mauticPlugins: ${typeof config.mauticPlugins}`, '🔬');
    if (config.mauticPlugins) {
      Logger.log('Condition (config.mauticPlugins) is TRUE. Plugin installation should start.', '✅');
    } else {
      Logger.log('Condition (config.mauticPlugins) is FALSE. Skipping plugin installation.', '❌');
    }
    Logger.log('--- ENDING DIAGNOSTICS ---', '🔬');
    // ======================================================================

    // Initialize deployment manager first to check installation status
    const deployer = new MauticDeployer(config);
    const sslManager = new SSLManager(config);

    // Check if Mautic is already installed
    const isInstalled = await deployer.isInstalled();

    if (isInstalled) {
      Logger.success('Existing Mautic installation detected - all packages already installed during VPS setup');
    } else {
      Logger.log('Fresh deployment detected - packages already installed during VPS setup', '🆕');

      // Stop unattended upgrades if they're still running
      Logger.log('Ensuring unattended-upgrades are stopped...', '🛑');
      await ProcessManager.runShell('systemctl stop unattended-upgrades', { ignoreError: true });
      await ProcessManager.runShell('pkill -f unattended-upgrade', { ignoreError: true });

      // Verify package availability
      Logger.log('Verifying package installations...', '🔍');
      const packageChecks = ['docker', 'nginx', 'curl', 'git'];
      for (const pkg of packageChecks) {
        const result = await ProcessManager.runShell(`which ${pkg}`, { ignoreError: true });
        if (result.success) {
          Logger.success(`✓ ${pkg} is available`);
        } else {
          Logger.warning(`⚠️ ${pkg} not found`);
        }
      }
    }

    if (isInstalled) {
      Logger.success('Existing Mautic installation detected');

      // Check if update is needed
      const needsUpdate = await deployer.needsUpdate();

      if (needsUpdate) {
        Logger.log('Update required, performing version update...', '🔄');
        const updateSuccess = await deployer.performUpdate();

        if (!updateSuccess) {
          throw new Error('Failed to update Mautic');
        }
      } else {
        Logger.success('Mautic is already up to date, no changes needed');
      }

      // Always install themes and plugins for existing installations 
      // (handles new plugins/themes or upgrades to existing ones)
      if (config.mauticThemes || config.mauticPlugins) {
        Logger.log('Installing/updating themes and plugins for existing installation...', '🎨');
        await deployer.installThemesAndPlugins();
        // Clear cache after installing packages
        await deployer.clearCache('after installing themes/plugins');
      }
    } else {
      Logger.log('No existing installation found, performing fresh installation...', '🆕');
      const installSuccess = await deployer.performInstallation();

      if (!installSuccess) {
        throw new Error('Failed to install Mautic');
      }
    }

    // Setup SSL if domain is provided
    if (config.domainName) {
      await sslManager.setupSSL();
    }

    // Final validation
    Logger.log('Performing final system validation...', '✅');
    const containers = await DockerManager.listMauticContainers();
    Logger.log(`Active containers: ${containers.length}`);

    for (const container of containers) {
      Logger.log(`  - ${container.name}: ${container.status} (${container.image})`);
    }

    // Test HTTP connectivity
    const baseUrl = config.domainName
      ? `http://${config.domainName}`
      : `http://${config.ipAddress}:${config.port}`;
    const testUrl = `${baseUrl}/s/login`;

    Logger.log(`Testing connectivity to: ${testUrl}`, '🌐');

    for (let attempt = 1; attempt <= 3; attempt++) {
      const curlResult = await ProcessManager.runShell(
        `curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 --max-time 30 "${testUrl}"`,
        { ignoreError: true }
      );

      if (curlResult.success && curlResult.output === '200') {
        Logger.success('✅ HTTP connectivity test passed');
        break;
      } else if (attempt === 3) {
        Logger.warning(`⚠️ HTTP test failed after 3 attempts (status: ${curlResult.output})`);
      } else {
        Logger.log(`HTTP test attempt ${attempt}/3 failed, retrying...`, '🔄');
        await new Promise(resolve => setTimeout(resolve, 15000));
      }
    }

    Logger.success('🎉 Mautic setup completed successfully!');
    Logger.log(`📍 Access URL: ${testUrl}`);
    Logger.log(`📧 Admin email: ${config.emailAddress}`);
    Logger.log(`🔒 Admin password: [configured]`);

    // Write completion marker for deploy script monitoring
    console.log('deployment_status::success');

    // Set output variables for GitHub Actions using environment files
    const outputFile = Deno.env.get("GITHUB_OUTPUT");
    if (outputFile) {
      const outputs = [
        `mautic_url=${baseUrl}`,
        `admin_email=${config.emailAddress}`,
        `deployment_status=success`
      ].join('\n') + '\n';

      await Deno.writeTextFile(outputFile, outputs, { append: true });
    } else {
      // Fallback for non-GitHub Actions environments
      console.log(`mautic_url=${baseUrl}`);
      console.log(`admin_email=${config.emailAddress}`);
      console.log(`deployment_status=success`);
    }

  } catch (error: unknown) {
    const errorMessage = error instanceof Error ? error.message : 'Unknown error';
    Logger.error(`Setup failed: ${errorMessage}`);
    Deno.exit(1);
  }
}

// Main execution
if (import.meta.main) {
  main();
}