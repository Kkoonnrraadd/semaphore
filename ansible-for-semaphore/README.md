# Ansible for Semaphore - Self-Service Data Refresh

This project provides Ansible automation for Semaphore to perform self-service data refresh operations on Azure SQL databases and related infrastructure.

## 🚀 Quick Start

### Prerequisites

- Ansible 2.9+ installed
- Azure CLI configured with appropriate permissions
- PowerShell Core (for script execution)
- Access to Azure subscriptions

### Basic Usage

1. **Test with dry run (recommended first step):**
   ```bash
   ./test_playbook.sh --dry-run
   ```

2. **Run full data refresh:**
   ```bash
   ./test_playbook.sh -s qa2 -d dev
   ```

3. **Copy database only (skip environment stop/start):**
   ```bash
   ./test_playbook.sh -o copy_database --skip-steps stop,start,adjust_resources
   ```

## 📁 Project Structure

```
ansible-for-semaphore/
├── playbooks/
│   ├── self_service_refresh.yaml    # 🆕 Main self-service playbook
│   └── data_refresh.yaml           # 📛 Deprecated (use above instead)
├── roles/
│   ├── self_service_refresh/       # 🆕 Enhanced self-service role
│   │   ├── tasks/                  # Ansible task definitions
│   │   └── files/                  # PowerShell scripts from SelfServiceRefresh/
│   ├── azure_database/             # Database operations
│   ├── azure_storage/              # Storage operations
│   ├── azure_kubernetes/           # AKS operations
│   ├── azure_monitor/              # Monitoring operations
│   ├── align-terraform-configuration/
│   └── align-runtime-configuration/
├── inventory/
│   ├── hosts.ini                   # Inventory configuration
│   └── group_vars/all.yml          # Global variables
├── semaphore/
│   └── project-templates.json      # Semaphore project templates
├── SelfServiceRefresh/             # 📁 Original PowerShell scripts (integrated)
├── test_playbook.sh               # 🆕 Testing script
├── ansible.cfg                    # Ansible configuration
└── README.md                      # This file
```

## 🎯 Available Operations

### Full Workflow
Executes the complete data refresh process:
1. Create restore point from source
2. Stop destination environment
3. Copy attachments and database
4. Adjust resources and configuration
5. Start destination environment
6. Clean up temporary resources
7. Manage permissions

### Individual Operations
- `restore_point` - Create point-in-time restore
- `copy_database` - Copy database only
- `copy_attachments` - Copy storage attachments
- `adjust_resources` - Reconfigure resources
- `start_environment` - Start services
- `stop_environment` - Stop services
- `cleanup` - Remove temporary resources
- `manage_permissions` - Update permissions

## 🔧 Configuration

### Environment Variables

The playbook supports flexible configuration through variables:

#### Required Variables
- `source_env` - Source environment name (e.g., "qa2")
- `dest_env` - Destination environment name (e.g., "dev")
- `source_sub_id` - Source Azure subscription ID
- `dest_sub_id` - Destination Azure subscription ID

#### Optional Variables
- `customer` - Customer alias (default: dest_env)
- `dry_run_mode` - Preview mode (default: false)
- `max_wait` - Maximum wait time in minutes (default: 10)
- `cloud` - Azure cloud environment (default: "AzureCloud")

#### Step Control Variables
Skip specific steps by setting these to `true`:
- `skip_restore_step`
- `skip_stop_step`
- `skip_copy_attachments_step`
- `skip_copy_database_step`
- `skip_adjust_resources_step`
- `skip_start_step`
- `skip_cleanup_step`
- `skip_permissions_step`

### Known Environments

The project includes pre-configured settings for:
- **qa2**: `e02ef4b1-a554-4934-89ef-3db39ce3f374`
- **dev**: `d602ec0b-96e4-44d2-8fb9-b79684a9489f`
- **hub**: `a9261cc1-d170-491d-b8fa-23ef0ad88ba3`

## 🧪 Testing

### Local Testing

Use the provided test script for comprehensive testing:

```bash
# Show all available options
./test_playbook.sh --help

# Dry run with verbose output
./test_playbook.sh --dry-run --verbose

# Syntax check only
./test_playbook.sh --check

# List all tasks
./test_playbook.sh --list-tasks

# Test specific operation
./test_playbook.sh -o copy_database --dry-run

# Skip certain steps
./test_playbook.sh --skip-steps stop,start --dry-run
```

### Direct Ansible Usage

```bash
# Basic dry run
ansible-playbook playbooks/self_service_refresh.yaml \
  -i inventory/hosts.ini \
  --extra-vars "source_env=qa2 dest_env=dev dry_run_mode=true"

# Full refresh with custom settings
ansible-playbook playbooks/self_service_refresh.yaml \
  -i inventory/hosts.ini \
  --extra-vars "source_env=qa2 dest_env=dev customer=mycustomer max_wait=15"

# Syntax check
ansible-playbook playbooks/self_service_refresh.yaml \
  -i inventory/hosts.ini \
  --check --diff
```

## 🎛️ Semaphore Integration

### Project Templates

The project includes pre-configured Semaphore templates in `semaphore/project-templates.json`:

1. **Self-Service Data Refresh - Full Workflow**
   - Complete data refresh with survey variables
   - Configurable source/destination environments
   - Dry run option available

2. **Self-Service Data Refresh - Dry Run**
   - Preview-only mode for testing
   - Safe to run in any environment

3. **Self-Service - Database Copy Only**
   - Database copy without environment stop/start
   - Useful for data-only refreshes

### Setting Up in Semaphore

1. **Create Project:**
   - Repository: Point to this Git repository
   - Playbook: `playbooks/self_service_refresh.yaml`
   - Inventory: `inventory/hosts.ini`

2. **Configure Environment:**
   - Set `AZURE_CONFIG_DIR=/home/semaphore/.azure`
   - Ensure Azure CLI is configured in the Semaphore environment

3. **Import Templates:**
   - Use the provided templates in `semaphore/project-templates.json`
   - Customize variables as needed for your environment

## 🔐 Security Considerations

### Azure Authentication
- Ensure Semaphore server has appropriate Azure service principal credentials
- Configure Azure CLI authentication in the Semaphore environment
- Use managed identities where possible

### Production Safety
- Always test with `dry_run_mode=true` first
- Use step control variables to skip potentially destructive operations
- Monitor logs during execution
- Have rollback procedures in place

### Access Control
- Limit access to production environments
- Use Semaphore's built-in access controls
- Audit all operations through Semaphore logs

## 📊 Monitoring and Logging

### Execution Logs
- All operations are logged with timestamps
- PowerShell script outputs are captured
- Ansible provides detailed task execution logs

### Health Monitoring
- Azure Monitor integration for environment health
- Automatic alert management during operations
- Post-operation health checks

## 🔧 Troubleshooting

### Common Issues

1. **PowerShell Script Failures:**
   - Check Azure CLI authentication
   - Verify subscription access permissions
   - Review script-specific error messages

2. **Environment Stop/Start Issues:**
   - Verify AKS cluster names and resource groups
   - Check Azure subscription permissions
   - Monitor for resource locks

3. **Database Copy Timeouts:**
   - Increase `max_wait` variable
   - Check database sizes and network connectivity
   - Monitor Azure portal for copy operation status

### Debug Mode

Enable verbose output for detailed troubleshooting:
```bash
./test_playbook.sh --verbose --dry-run
```

Or with direct Ansible:
```bash
ansible-playbook playbooks/self_service_refresh.yaml -vvv
```

## 🚀 Migration from Legacy Scripts

### From SelfServiceRefresh PowerShell Scripts

The original PowerShell scripts in `SelfServiceRefresh/` have been integrated into the Ansible role structure. Key improvements:

- **Unified orchestration** through Ansible
- **Better error handling** and rollback capabilities
- **Integration with existing Azure roles**
- **Semaphore-ready** configuration
- **Comprehensive logging** and monitoring

### Migration Steps

1. **Replace direct PowerShell usage** with the Ansible playbook
2. **Update Semaphore projects** to use the new templates
3. **Test thoroughly** in non-production environments
4. **Update documentation** and procedures

## 📝 Contributing

1. Test changes with `./test_playbook.sh --check`
2. Use dry run mode for testing: `./test_playbook.sh --dry-run`
3. Follow Ansible best practices
4. Update documentation for any new features

## 📄 License

This project is part of the Manufacturo internal automation toolkit.

---

For additional support or questions, please refer to the Manufacturo DevOps documentation or contact the infrastructure team.