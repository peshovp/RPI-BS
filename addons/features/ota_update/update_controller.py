"""
OTA Update Controller
Handles web-based updates for GeoMaxima
"""

import subprocess
import os
import logging
from pathlib import Path
from typing import Dict, Optional, List, Tuple
from datetime import datetime
import threading
import json
import shlex
import tempfile
import glob

logger = logging.getLogger(__name__)


class UpdateController:
    """Manages over-the-air updates for GeoMaxima"""
    
    def __init__(self, repo_path: str = None, git_user: str = 'peshovp'):
        """
        Initialize update controller

        Args:
            repo_path: Path to GeoMaxima repository (auto-detected if None)
            git_user: User to run git commands as (default: peshovp)

        Note: The 'peshovp' default is an intentional match with the current
        single-user deploy environment (this is the actual system/repo owner
        on the deployed device), not a universal default. If this project is
        ever deployed under a different Linux user, this must be passed
        explicitly rather than relying on the default.
        """
        if repo_path is None:
            # Auto-detect repository path
            repo_path = self._find_repo_path()
        
        self.repo_path = Path(repo_path)
        self.git_user = git_user
        self.update_lock = threading.Lock()
        self.update_in_progress = False
        self.last_update_status = None
        self.status_file = self.repo_path / '.update_status.json'
        self.token_file = self.repo_path / '.github_token'
        self._askpass_script = self.repo_path / '.git_askpass.sh'
        self.github_token: Optional[str] = None

        # If status says "in progress" for too long, treat as stale and allow a new run
        # (prevents permanent lock if background script crashed or never updated status)
        try:
            self.stale_timeout_minutes = int(os.environ.get('OTA_UPDATE_STALE_MINUTES', '60'))
        except Exception:
            self.stale_timeout_minutes = 60
        
        # Load last status from file (survives service restart)
        self._load_status_from_file()
        self._load_token()
        
        logger.info(f"UpdateController initialized: {self.repo_path}, user: {self.git_user}")

    def _load_token(self):
        """Load GitHub token from local file if present"""
        try:
            if self.token_file.exists():
                self.github_token = self.token_file.read_text().strip() or None
                if self.github_token:
                    logger.info("GitHub token loaded (masked)")
        except Exception as e:
            logger.warning(f"Failed to load GitHub token: {e}")

    def set_github_token(self, token: str) -> bool:
        """Persist GitHub token for private OTA repo"""
        try:
            token = (token or "").strip()
            if not token:
                # Clear token
                if self.token_file.exists():
                    self.token_file.unlink()
                self.github_token = None
                return True
            self.token_file.write_text(token)
            os.chmod(self.token_file, 0o600)
            self.github_token = token
            # Refresh askpass script
            if self._askpass_script.exists():
                self._askpass_script.unlink()
            return True
        except Exception as e:
            logger.error(f"Failed to save GitHub token: {e}")
            return False

    def is_token_configured(self) -> bool:
        return bool(self.github_token)

    def _ensure_askpass(self) -> Optional[str]:
        """Ensure a GIT_ASKPASS script exists and return its path"""
        if not self.github_token:
            return None
        try:
            content = """#!/bin/bash
prompt="$1"
if echo "$prompt" | grep -qi "username"; then
  echo "x-access-token"
else
  echo "%(token)s"
fi
""" % {"token": self.github_token}
            self._askpass_script.write_text(content)
            os.chmod(self._askpass_script, 0o700)
            return str(self._askpass_script)
        except Exception as e:
            logger.error(f"Failed to create GIT_ASKPASS script: {e}")
            return None

    def _git_env(self, base_env: Optional[Dict[str, str]] = None) -> Dict[str, str]:
        env = dict(base_env or os.environ)
        env['GIT_TERMINAL_PROMPT'] = '0'
        if self.github_token:
            askpass = self._ensure_askpass()
            if askpass:
                env['GIT_ASKPASS'] = askpass
        return env
    
    def _load_status_from_file(self):
        """Load last update status from persistent file"""
        try:
            if self.status_file.exists():
                with open(self.status_file, 'r') as f:
                    self.last_update_status = json.load(f)
                logger.info(f"Loaded update status from file: completed={self.last_update_status.get('completed')}")
        except Exception as e:
            logger.warning(f"Failed to load update status: {e}")
    
    def _save_status_to_file(self):
        """Save update status to persistent file (survives service restart)"""
        try:
            self.status_file.parent.mkdir(parents=True, exist_ok=True)
            with open(self.status_file, 'w') as f:
                json.dump(self.last_update_status, f, indent=2)
            logger.info(f"Saved update status to file: completed={self.last_update_status.get('completed')}")
        except Exception as e:
            logger.error(f"Failed to save update status: {e}")
    
    def _run_git_command(self, args: List[str], **kwargs) -> subprocess.CompletedProcess:
        """
        Run git command as the correct user
        
        Args:
            args: Git command arguments (e.g., ['fetch', 'origin'])
            **kwargs: Additional subprocess.run() arguments
        
        Returns:
            CompletedProcess object
        """
        # Build git command
        cmd = ['git', '-C', str(self.repo_path)] + args

        # Environment with optional token
        env = self._git_env(kwargs.pop('env', None))
        
        # Try to detect if we need sudo (check current user vs repo owner)
        try:
            import pwd
            repo_stat = os.stat(self.repo_path)
            repo_owner = pwd.getpwuid(repo_stat.st_uid).pw_name
            current_user = pwd.getpwuid(os.getuid()).pw_name
            
            # If we're not the repo owner, use sudo
            if current_user != repo_owner and current_user == 'root':
                cmd = ['sudo', '-u', repo_owner] + cmd
                logger.info(f"Running git as {repo_owner} (current: {current_user})")
        except Exception as e:
            # On systems without pwd module or permission issues, run normally
            logger.debug(f"Could not detect user context: {e}")
        
        logger.debug(f"Git command: {' '.join(cmd)}")
        return subprocess.run(cmd, env=env, **kwargs)
    
    def _find_repo_path(self) -> str:
        """
        Compute the repo root path directly from this file's location.
        This file lives at <repo_root>/addons/features/ota_update/update_controller.py,
        so four parent levels up is always the repo root - no candidate search needed,
        since dev repo and deployed app are the same single repo in this architecture.
        """
        repo_root = Path(__file__).resolve().parent.parent.parent.parent
        if not (repo_root / '.git').exists():
            raise RuntimeError(f"Expected git repo at {repo_root}, but no .git directory found")
        return str(repo_root)
    
    def get_current_version(self) -> Dict:
        """
        Get current installed version info
        
        Returns:
            Dict with version, commit, branch, date
        """
        try:
            # Get current branch
            branch = self._run_git_command(
                ['rev-parse', '--abbrev-ref', 'HEAD'],
                capture_output=True, text=True, check=True
            ).stdout.strip()
            
            # Get current commit hash
            commit = self._run_git_command(
                ['rev-parse', 'HEAD'],
                capture_output=True, text=True, check=True
            ).stdout.strip()
            
            commit_short = commit[:7]
            
            # Get commit date
            commit_date = self._run_git_command(
                ['log', '-1', '--format=%ci'],
                capture_output=True, text=True, check=True
            ).stdout.strip()
            
            # Get commit message
            commit_msg = self._run_git_command(
                ['log', '-1', '--format=%s'],
                capture_output=True, text=True, check=True
            ).stdout.strip()
            
            # Read VERSION file if exists
            version_file = self.repo_path / 'VERSION'
            version = version_file.read_text().strip() if version_file.exists() else 'Unknown'
            
            # Check for uncommitted changes
            status = self._run_git_command(
                ['status', '--porcelain'],
                capture_output=True, text=True, check=True
            ).stdout.strip()
            
            has_changes = bool(status)
            
            return {
                'version': version,
                'branch': branch,
                'commit': commit,
                'commit_short': commit_short,
                'commit_date': commit_date,
                'commit_message': commit_msg,
                'has_uncommitted_changes': has_changes,
                'repo_path': str(self.repo_path)
            }
            
        except Exception as e:
            logger.error(f"Failed to get version info: {e}")
            return {
                'version': 'Unknown',
                'error': str(e)
            }
    
    def check_for_updates(self) -> Dict:
        """
        Check if updates are available from remote
        
        Returns:
            Dict with available updates info
        """
        try:
            # Fetch latest from remote with token auth if configured
            env = self._git_env()
            
            # Retry fetch up to 3 times with exponential backoff
            max_retries = 3
            last_error = None
            
            for attempt in range(max_retries):
                try:
                    result = self._run_git_command(
                        ['fetch', 'origin'],
                        capture_output=True, text=True, timeout=30, env=env
                    )
                    
                    if result.returncode == 0:
                        break  # Success
                    
                    last_error = result.stderr.strip()
                    logger.warning(f"Git fetch attempt {attempt+1}/{max_retries} failed: {last_error}")
                    
                    if attempt < max_retries - 1:
                        import time
                        time.sleep(2 ** attempt)  # 1s, 2s, 4s
                        
                except subprocess.TimeoutExpired:
                    last_error = "Network timeout"
                    logger.warning(f"Git fetch attempt {attempt+1}/{max_retries} timed out")
                    if attempt < max_retries - 1:
                        import time
                        time.sleep(2 ** attempt)
            else:
                # All retries failed
                error_msg = f"Failed to fetch after {max_retries} attempts: {last_error or 'Unknown error'}"
                logger.error(error_msg)
                return {'error': error_msg}
            
            # Get current branch
            branch = self._run_git_command(
                ['rev-parse', '--abbrev-ref', 'HEAD'],
                capture_output=True, text=True, check=True
            ).stdout.strip()
            
            # Get local commit
            local_commit = self._run_git_command(
                ['rev-parse', 'HEAD'],
                capture_output=True, text=True, check=True
            ).stdout.strip()
            
            # Get remote commit
            remote_commit = self._run_git_command(
                ['rev-parse', f'origin/{branch}'],
                capture_output=True, text=True, check=True
            ).stdout.strip()
            
            updates_available = local_commit != remote_commit
            
            # Get commits behind
            if updates_available:
                commits_behind = self._run_git_command(
                    ['rev-list', '--count', f'HEAD..origin/{branch}'],
                    capture_output=True, text=True, check=True
                ).stdout.strip()
                
                # Get changelog
                changelog = self._run_git_command(
                    ['log', '--oneline', f'HEAD..origin/{branch}'],
                    capture_output=True, text=True, check=True
                ).stdout.strip()
                
                return {
                    'updates_available': True,
                    'commits_behind': int(commits_behind),
                    'local_commit': local_commit[:7],
                    'remote_commit': remote_commit[:7],
                    'changelog': changelog,
                    'branch': branch
                }
            else:
                return {
                    'updates_available': False,
                    'message': 'Already up to date',
                    'branch': branch
                }
                
        except subprocess.TimeoutExpired:
            logger.error("Git fetch timeout")
            return {'error': 'Network timeout - check internet connection'}
        except Exception as e:
            logger.error(f"Failed to check updates: {e}")
            return {'error': str(e)}
    
    def perform_update(self, restart_service: bool = True) -> Dict:
        """
        Perform OTA update using detached background script
        
        Args:
            restart_service: Whether to restart rtkbase_web service after update
            
        Returns:
            Dict with update status
        """
        # Always refresh state from status file first (update runs detached)
        current_status = self.get_update_status()
        if current_status.get('update_in_progress'):
            # Idempotent: report that it's running
            return {'success': True, 'status': 'in_progress', 'message': 'Update already in progress'}

        self.update_in_progress = True
        
        try:
            # Initialize status
            self.last_update_status = {
                'success': False,
                'timestamp': datetime.now().isoformat(),
                'log': 'Launching update process...\n',
                'completed': False
            }
            self._save_status_to_file()
            
            # Use standalone update script that runs independently
            update_script = self.repo_path / 'addons' / 'tools' / 'perform_update.sh'
            status_file = self.repo_path / '.update_status.json'

            if not update_script.exists():
                error_msg = f"Update script not found: {update_script}"
                logger.error(error_msg)
                self.last_update_status = {
                    'success': False,
                    'error': error_msg,
                    'log': f'❌ {error_msg}',
                    'completed': True
                }
                self._save_status_to_file()
                return self.last_update_status
            
            # Make script executable
            import os
            os.chmod(update_script, 0o755)
            
            # Launch update script in fully detached background process
            logger.info(f"Launching detached update script: {update_script}")
            logger.info(f"Status file: {status_file}")

            # Use nohup and background process to survive Flask restart
            # Pass repo_path and status_file as arguments (dev repo and
            # deployed app are the same single repo, so only one path is needed)
            cmd = [
                'nohup',
                'bash',
                str(update_script),
                str(self.repo_path),
                str(status_file)
            ]

            subprocess.Popen(
                cmd,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
                cwd=str(self.repo_path)
            )
            
            logger.info("✓ Update script launched successfully in background")
            
            # Update status to indicate background process started
            self.last_update_status = {
                'success': None,  # Unknown yet
                'timestamp': datetime.now().isoformat(),
                'log': 'Update running in background...\nCheck status below for progress.\n(Page will refresh automatically when complete)',
                'completed': False
            }
            self._save_status_to_file()
            
            return {'success': True, 'status': 'in_progress', 'message': 'Update started in background'}
            
        except Exception as e:
            error_msg = f"Failed to launch update: {type(e).__name__}: {str(e)}"
            logger.error(error_msg, exc_info=True)
            
            self.last_update_status = {
                'success': False,
                'error': error_msg,
                'log': f'❌ {error_msg}',
                'completed': True
            }
            self._save_status_to_file()
            return self.last_update_status

        finally:
            # The background script is responsible for final completion,
            # but ensure we don't leave an in-memory lock set on exceptions.
            if self.last_update_status and self.last_update_status.get('completed', False):
                self.update_in_progress = False

    def _status_timestamp(self) -> Optional[datetime]:
        ts = None
        try:
            ts = (self.last_update_status or {}).get('timestamp')
            if not ts:
                return None
            # Python 3.11+: supports fromisoformat for our stored format
            return datetime.fromisoformat(ts)
        except Exception:
            return None

    def _maybe_clear_stale_in_progress(self) -> bool:
        """If status is 'in progress' for too long, mark it failed+completed.

        Returns True if we modified status.
        """
        if not self.last_update_status:
            return False
        if self.last_update_status.get('completed', True):
            return False

        started = self._status_timestamp()
        if not started:
            return False

        age_minutes = (datetime.now() - started).total_seconds() / 60.0
        if age_minutes < float(self.stale_timeout_minutes):
            return False

        msg = (
            f"⚠ Update status was stuck in-progress for ~{int(age_minutes)} minutes; "
            f"marking as failed and unlocking. (Set OTA_UPDATE_STALE_MINUTES to adjust.)"
        )
        log = (self.last_update_status.get('log') or '')
        if log and not log.endswith('\n'):
            log += '\n'
        log += msg + '\n'

        self.last_update_status = {
            **self.last_update_status,
            'success': False,
            'error': 'Stale in-progress update cleared',
            'log': log,
            'completed': True,
            'timestamp': datetime.now().isoformat()
        }
        self._save_status_to_file()
        self.update_in_progress = False
        return True
    
    def _old_perform_update(self, restart_service: bool = True) -> Dict:
        """
        Perform OTA update
        
        Args:
            restart_service: Whether to restart rtkbase_web service after update
            
        Returns:
            Dict with update status
        """
        if self.update_in_progress:
            return {'success': False, 'error': 'Update already in progress'}
        
        with self.update_lock:
            self.update_in_progress = True
            
            # Clear previous completed status when starting new update
            self.last_update_status = {
                'success': False,
                'timestamp': datetime.now().isoformat(),
                'log': 'Update started...',
                'completed': False  # Not completed yet
            }
            self._save_status_to_file()
            
            update_log = []
            
            try:
                # Step 1: Stash any local changes
                update_log.append("Stashing local changes...")
                logger.info("Starting git stash...")
                self.last_update_status['log'] = '\n'.join(update_log)
                self._save_status_to_file()
                
                result = self._run_git_command(
                    ['stash', 'push', '-m', f'Auto-stash before OTA update {datetime.now().isoformat()}'],
                    capture_output=True, text=True
                )
                if result.returncode == 0:
                    update_log.append("✓ Local changes stashed")
                    logger.info("Git stash successful")
                else:
                    update_log.append(f"Note: {result.stderr.strip()[:200]}")
                    logger.warning(f"Git stash: {result.stderr}")
                
                self.last_update_status['log'] = '\n'.join(update_log)
                self._save_status_to_file()
                
                # Step 2: Fetch latest
                update_log.append("Fetching latest updates...")
                logger.info("Starting git fetch...")
                self.last_update_status['log'] = '\n'.join(update_log)
                self._save_status_to_file()
                
                result = self._run_git_command(
                    ['fetch', 'origin'],
                    capture_output=True, text=True, timeout=30
                )
                if result.returncode != 0:
                    error_msg = f"Git fetch failed: {result.stderr}"
                    logger.error(error_msg)
                    update_log.append(f"❌ {error_msg}")
                    self.last_update_status['log'] = '\n'.join(update_log)
                    self._save_status_to_file()
                    raise RuntimeError(error_msg)
                update_log.append("✓ Fetched from origin")
                logger.info("Git fetch successful")
                
                self.last_update_status['log'] = '\n'.join(update_log)
                self._save_status_to_file()
                
                # Step 3: Get current branch
                update_log.append("Getting current branch...")
                self.last_update_status['log'] = '\n'.join(update_log)
                self._save_status_to_file()
                
                branch = self._run_git_command(
                    ['rev-parse', '--abbrev-ref', 'HEAD'],
                    capture_output=True, text=True
                )
                if branch.returncode != 0:
                    error_msg = f"Failed to get branch: {branch.stderr}"
                    logger.error(error_msg)
                    update_log.append(f"❌ {error_msg}")
                    self.last_update_status['log'] = '\n'.join(update_log)
                    self._save_status_to_file()
                    raise RuntimeError(error_msg)
                branch = branch.stdout.strip()
                logger.info(f"Current branch: {branch}")
                update_log.append(f"✓ Current branch: {branch}")
                
                self.last_update_status['log'] = '\n'.join(update_log)
                self._save_status_to_file()
                
                # Step 4: Pull updates
                update_log.append(f"Pulling updates from {branch}...")
                logger.info(f"Starting git pull from {branch}...")
                self.last_update_status['log'] = '\n'.join(update_log)
                self._save_status_to_file()
                
                result = self._run_git_command(
                    ['pull', 'origin', branch],
                    capture_output=True, text=True, timeout=60
                )
                if result.returncode != 0:
                    error_msg = f"Git pull failed: {result.stderr}"
                    logger.error(error_msg)
                    update_log.append(f"❌ {error_msg}")
                    self.last_update_status['log'] = '\n'.join(update_log)
                    self._save_status_to_file()
                    raise RuntimeError(error_msg)
                update_log.append("✓ Updates pulled successfully")
                logger.info(f"Git pull successful: {result.stdout.strip()}")
                
                self.last_update_status['log'] = '\n'.join(update_log)
                self._save_status_to_file()
                
                # Step 5: Run install script (optional)
                install_script = self.repo_path / 'install_local.sh'
                if install_script.exists():
                    update_log.append("Running install script...")
                    logger.info(f"Running install script: {install_script}")
                    self.last_update_status['log'] = '\n'.join(update_log)
                    self._save_status_to_file()
                    
                    try:
                        result = subprocess.run(
                            ['sudo', 'bash', str(install_script)],
                            capture_output=True, text=True, timeout=300
                        )
                        if result.returncode == 0:
                            update_log.append("✓ Installation completed")
                            logger.info("Install script successful")
                            if result.stdout:
                                update_log.append(f"Install output:\n{result.stdout[-500:]}")
                        else:
                            # Install script failed but continue (may not be critical)
                            logger.warning(f"Install script returned {result.returncode}: {result.stderr}")
                            update_log.append(f"⚠ Install script warning (continuing): {result.stderr[-200:]}")
                    except subprocess.TimeoutExpired:
                        logger.warning("Install script timeout (continuing)")
                        update_log.append("⚠ Install script timeout (continuing)")
                    except Exception as e:
                        logger.warning(f"Install script error (continuing): {e}")
                        update_log.append(f"⚠ Install script error (continuing): {str(e)[:200]}")
                    
                    self.last_update_status['log'] = '\n'.join(update_log)
                    self._save_status_to_file()
                else:
                    logger.info(f"Install script not found (skipping): {install_script}")
                    update_log.append("ℹ No install script found (files updated via git pull)")
                    self.last_update_status['log'] = '\n'.join(update_log)
                    self._save_status_to_file()
                
                # Step 5.5: Sync to deployed location if needed
                deployed_path = Path('/home') / self.git_user / 'rtkbase' / 'geomaxima'
                if deployed_path.exists() and deployed_path != self.repo_path:
                    update_log.append("Syncing to deployed location...")
                    logger.info(f"Syncing {self.repo_path} → {deployed_path}")
                    self.last_update_status['log'] = '\n'.join(update_log)
                    self._save_status_to_file()
                    
                    try:
                        # Use rsync to copy files (excluding .git)
                        result = subprocess.run(
                            ['rsync', '-av', '--delete', '--exclude=.git', 
                             f'{self.repo_path}/', f'{deployed_path}/'],
                            capture_output=True, text=True, timeout=60
                        )
                        if result.returncode == 0:
                            update_log.append("✓ Files synced to deployed location")
                            logger.info("Rsync successful")
                        else:
                            logger.warning(f"Rsync failed (continuing): {result.stderr}")
                            update_log.append(f"⚠ Sync warning: {result.stderr[-200:]}")
                        
                        self.last_update_status['log'] = '\n'.join(update_log)
                        self._save_status_to_file()
                        
                    except Exception as e:
                        logger.warning(f"Sync error (continuing): {e}")
                        update_log.append(f"⚠ Sync skipped: {str(e)[:100]}")
                        self.last_update_status['log'] = '\n'.join(update_log)
                        self._save_status_to_file()
                
                # Success - update completed
                new_version = self.get_current_version()
                update_log.append(f"\n✅ Update completed successfully!")
                update_log.append(f"New version: {new_version.get('commit_short', 'Unknown')}")
                update_log.append(f"\n⚠ IMPORTANT: Please restart the service manually:")
                update_log.append(f"   sudo systemctl restart rtkbase_web")
                update_log.append(f"   or refresh this page to apply changes")
                
                self.last_update_status = {
                    'success': True,
                    'timestamp': datetime.now().isoformat(),
                    'log': '\n'.join(update_log),
                    'new_version': new_version,
                    'completed': True
                }
                self._save_status_to_file()
                
                return self.last_update_status
                
            except subprocess.TimeoutExpired as e:
                error_msg = f"Update timeout: {e}"
                logger.error(error_msg)
                update_log.append(f"❌ {error_msg}")
                
                self.last_update_status = {
                    'success': False,
                    'error': error_msg,
                    'log': '\n'.join(update_log),
                    'completed': True  # Mark completed even on error
                }
                self._save_status_to_file()
                return self.last_update_status
                
            except Exception as e:
                error_msg = f"Update failed: {type(e).__name__}: {str(e)}"
                logger.error(error_msg, exc_info=True)
                update_log.append(f"❌ {error_msg}")
                
                # Add traceback to log for debugging
                import traceback
                tb = traceback.format_exc()
                logger.error(f"Full traceback:\n{tb}")
                update_log.append(f"\nError details: {tb[:500]}")
                
                self.last_update_status = {
                    'success': False,
                    'error': error_msg,
                    'log': '\n'.join(update_log),
                    'completed': True  # Mark completed even on error
                }
                self._save_status_to_file()
                return self.last_update_status
                
            finally:
                self.update_in_progress = False
    
    def get_update_status(self) -> Dict:
        """Get status of last update operation"""
        # Always reload from status file to reflect background script progress
        self._load_status_from_file()
        self._maybe_clear_stale_in_progress()
        # Infer in-progress state from 'completed' flag when background script runs
        if self.last_update_status and not self.last_update_status.get('completed', True):
            self.update_in_progress = True
        elif self.last_update_status and self.last_update_status.get('completed', False):
            self.update_in_progress = False
        return {
            'update_in_progress': self.update_in_progress,
            'last_update': self.last_update_status
        }
    
    def get_git_log(self, limit: int = 20) -> List[Dict]:
        """
        Get recent git commits
        
        Args:
            limit: Number of commits to retrieve
            
        Returns:
            List of commit dicts
        """
        try:
            # Get commits with formatted output
            result = self._run_git_command(
                ['log', f'-{limit}', '--format=%H|%h|%an|%ae|%ci|%s'],
                capture_output=True, text=True, check=True
            )
            
            commits = []
            for line in result.stdout.strip().split('\n'):
                if not line:
                    continue
                parts = line.split('|', 5)
                if len(parts) == 6:
                    commits.append({
                        'hash': parts[0],
                        'hash_short': parts[1],
                        'author': parts[2],
                        'author_email': parts[3],
                        'date': parts[4],
                        'message': parts[5]
                    })
            
            return commits
            
        except Exception as e:
            logger.error(f"Failed to get git log: {e}")
            return []
    
    def rollback_to_commit(self, commit_hash: str, restart_service: bool = True) -> Dict:
        """
        Rollback to a previous commit
        
        Args:
            commit_hash: Git commit hash to rollback to
            restart_service: Whether to restart rtkbase_web after rollback
            
        Returns:
            Dict with rollback status
        """
        if self.update_in_progress:
            return {'success': False, 'error': 'Update/rollback already in progress'}
        
        with self.update_lock:
            self.update_in_progress = True
            rollback_log = []
            
            try:
                # Validate commit hash exists
                rollback_log.append(f"Validating commit {commit_hash[:7]}...")
                result = self._run_git_command(
                    ['cat-file', '-t', commit_hash],
                    capture_output=True, text=True
                )
                if result.returncode != 0:
                    raise ValueError(f"Invalid commit hash: {commit_hash}")
                rollback_log.append("✓ Commit is valid")
                
                # Get current commit for safety
                current_commit = self._run_git_command(
                    ['rev-parse', 'HEAD'],
                    capture_output=True, text=True, check=True
                ).stdout.strip()
                rollback_log.append(f"Current commit: {current_commit[:7]}")
                
                # Stash any local changes
                rollback_log.append("Stashing local changes...")
                result = self._run_git_command(
                    ['stash', 'push', '-m', f'Auto-stash before rollback {datetime.now().isoformat()}'],
                    capture_output=True, text=True
                )
                if result.returncode == 0:
                    rollback_log.append("✓ Local changes stashed")
                
                # Perform hard reset to target commit
                rollback_log.append(f"Rolling back to {commit_hash[:7]}...")
                result = self._run_git_command(
                    ['reset', '--hard', commit_hash],
                    capture_output=True, text=True, check=True
                )
                rollback_log.append("✓ Rollback completed")

                # Restart service if requested
                if restart_service:
                    rollback_log.append("Restarting rtkbase_web service...")
                    result = subprocess.run(
                        ['sudo', 'systemctl', 'restart', 'rtkbase_web'],
                        capture_output=True, text=True
                    )
                    if result.returncode == 0:
                        rollback_log.append("✓ Service restarted")
                    else:
                        rollback_log.append("⚠ Service restart may have failed")
                
                success_msg = f"Successfully rolled back to {commit_hash[:7]}"
                logger.info(success_msg)
                rollback_log.append(f"✓ {success_msg}")
                
                self.last_update_status = {
                    'success': True,
                    'message': success_msg,
                    'previous_commit': current_commit[:7],
                    'new_commit': commit_hash[:7],
                    'log': '\n'.join(rollback_log),
                    'completed': True  # Rollback completed
                }
                self._save_status_to_file()
                return self.last_update_status
                
            except Exception as e:
                error_msg = f"Rollback failed: {e}"
                logger.error(error_msg)
                rollback_log.append(f"❌ {error_msg}")
                
                self.last_update_status = {
                    'success': False,
                    'error': error_msg,
                    'log': '\n'.join(rollback_log),
                    'completed': True  # Mark completed even on error
                }
                self._save_status_to_file()
                return self.last_update_status
                
            finally:
                self.update_in_progress = False
    
    def get_previous_commit(self) -> Optional[Dict]:
        """
        Get the previous commit (for quick rollback)
        
        Returns:
            Dict with previous commit info or None
        """
        try:
            result = self._run_git_command(
                ['log', '-2', '--format=%H|%h|%an|%ci|%s'],
                capture_output=True, text=True, check=True
            )
            
            lines = result.stdout.strip().split('\n')
            if len(lines) >= 2:
                parts = lines[1].split('|', 4)
                if len(parts) == 5:
                    return {
                        'hash': parts[0],
                        'hash_short': parts[1],
                        'author': parts[2],
                        'date': parts[3],
                        'message': parts[4]
                    }
            return None
            
        except Exception as e:
            logger.error(f"Failed to get previous commit: {e}")
            return None
