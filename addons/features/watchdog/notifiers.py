"""
Notification handlers for Watchdog incidents
"""

import logging
import smtplib
import requests
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from typing import List, Dict
from datetime import datetime

logger = logging.getLogger(__name__)


class EmailNotifier:
    """Send email notifications via SMTP"""
    
    def __init__(self, config: Dict):
        """
        Initialize email notifier
        
        Args:
            config: Email notification configuration
        """
        self.config = config
        self.enabled = config.get('enabled', False)
    
    def send(self, incidents: List[Dict]) -> bool:
        """
        Send email notification with incidents
        
        Args:
            incidents: List of incident dictionaries
            
        Returns:
            True if sent successfully
        """
        if not self.enabled:
            return False
        
        try:
            # Prepare email
            msg = MIMEMultipart()
            msg['From'] = self.config.get('from_address', 'watchdog@rtkbase.local')
            msg['To'] = ', '.join(self.config.get('to_addresses', []))
            msg['Subject'] = f'GeoMaxima Watchdog Alert - {len(incidents)} Incident(s)'
            
            # Build email body
            body = self._build_email_body(incidents)
            msg.attach(MIMEText(body, 'html'))
            
            # Send via SMTP
            smtp_server = self.config.get('smtp_server')
            smtp_port = self.config.get('smtp_port', 587)
            smtp_user = self.config.get('smtp_user', msg['From'])
            smtp_password = self.config.get('smtp_password', '')
            use_tls = self.config.get('use_tls', True)
            
            if not smtp_server:
                logger.error("SMTP server not configured")
                return False
            
            with smtplib.SMTP(smtp_server, smtp_port, timeout=10) as server:
                if use_tls:
                    server.starttls()
                
                if smtp_password:
                    server.login(smtp_user, smtp_password)
                
                server.send_message(msg)
            
            logger.info(f"Email notification sent to {msg['To']}")
            return True
            
        except Exception as e:
            logger.error(f"Failed to send email notification: {e}")
            return False
    
    def _build_email_body(self, incidents: List[Dict]) -> str:
        """Build HTML email body"""
        html = f"""
        <html>
        <head>
            <style>
                body {{ font-family: Arial, sans-serif; }}
                .header {{ background: #ef4444; color: white; padding: 20px; }}
                .incident {{ border-left: 4px solid #ef4444; padding: 10px; margin: 10px 0; background: #fee2e2; }}
                .incident.warning {{ border-color: #f59e0b; background: #fef3c7; }}
                .severity {{ font-weight: bold; text-transform: uppercase; }}
                .timestamp {{ color: #666; font-size: 0.9em; }}
            </style>
        </head>
        <body>
            <div class="header">
                <h2>🐕 GeoMaxima Watchdog Alert</h2>
                <p>Detected {len(incidents)} incident(s) requiring attention</p>
            </div>
            <div style="padding: 20px;">
                <p><strong>Time:</strong> {datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S')} UTC</p>
                <h3>Incidents:</h3>
        """
        
        for incident in incidents:
            severity = incident.get('severity', 'warning')
            css_class = 'incident warning' if severity == 'warning' else 'incident'
            
            html += f"""
                <div class="{css_class}">
                    <div class="severity">{severity}: {incident.get('type', 'unknown')}</div>
                    <div>{incident.get('message', 'No details')}</div>
                    <div class="timestamp">{incident.get('timestamp', '')}</div>
                </div>
            """
        
        html += """
                <hr>
                <p style="color: #666; font-size: 0.9em;">
                    This is an automated message from GeoMaxima Watchdog system.
                    <br>To manage notifications, visit: http://your-rtkbase/geomaxima/watchdog
                </p>
            </div>
        </body>
        </html>
        """
        
        return html


class TelegramNotifier:
    """Send Telegram notifications via Bot API"""
    
    def __init__(self, config: Dict):
        """
        Initialize Telegram notifier
        
        Args:
            config: Telegram notification configuration
        """
        self.config = config
        self.enabled = config.get('enabled', False)
        self.bot_token = config.get('bot_token', '')
        self.chat_id = config.get('chat_id', '')
    
    def send(self, incidents: List[Dict]) -> bool:
        """
        Send Telegram notification with incidents
        
        Args:
            incidents: List of incident dictionaries
            
        Returns:
            True if sent successfully
        """
        if not self.enabled:
            return False
        
        if not self.bot_token or not self.chat_id:
            logger.error("Telegram bot_token or chat_id not configured")
            return False
        
        try:
            # Build message
            message = self._build_telegram_message(incidents)
            
            # Send via Telegram API
            url = f"https://api.telegram.org/bot{self.bot_token}/sendMessage"
            
            payload = {
                'chat_id': self.chat_id,
                'text': message,
                'parse_mode': 'HTML',
                'disable_web_page_preview': True
            }
            
            response = requests.post(url, json=payload, timeout=10)
            response.raise_for_status()
            
            logger.info(f"Telegram notification sent to chat {self.chat_id}")
            return True
            
        except Exception as e:
            logger.error(f"Failed to send Telegram notification: {e}")
            return False
    
    def _build_telegram_message(self, incidents: List[Dict]) -> str:
        """Build Telegram message text"""
        severity_emoji = {
            'critical': '🔴',
            'warning': '⚠️',
            'info': 'ℹ️'
        }
        
        message = f"🐕 <b>GeoMaxima Watchdog Alert</b>\n"
        message += f"📅 {datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S')} UTC\n"
        message += f"📊 {len(incidents)} incident(s) detected\n\n"
        
        for i, incident in enumerate(incidents, 1):
            severity = incident.get('severity', 'info')
            emoji = severity_emoji.get(severity, 'ℹ️')
            
            message += f"{emoji} <b>{incident.get('type', 'unknown')}</b>\n"
            message += f"   {incident.get('message', 'No details')}\n"
            
            if i < len(incidents):
                message += "\n"
        
        message += "\n<i>Configure: /geomaxima/watchdog</i>"
        
        return message


def test_email_config(config: Dict) -> Dict:
    """
    Test email configuration
    
    Args:
        config: Email config to test
        
    Returns:
        Dict with test results
    """
    try:
        notifier = EmailNotifier(config)
        test_incident = [{
            'type': 'test',
            'severity': 'info',
            'message': 'This is a test notification from GeoMaxima Watchdog',
            'timestamp': datetime.utcnow().isoformat()
        }]
        
        success = notifier.send(test_incident)
        
        return {
            'success': success,
            'message': 'Test email sent successfully' if success else 'Failed to send test email'
        }
    except Exception as e:
        return {
            'success': False,
            'message': f'Email test failed: {str(e)}'
        }


def test_telegram_config(config: Dict) -> Dict:
    """
    Test Telegram configuration
    
    Args:
        config: Telegram config to test
        
    Returns:
        Dict with test results
    """
    try:
        notifier = TelegramNotifier(config)
        test_incident = [{
            'type': 'test',
            'severity': 'info',
            'message': '✅ Test notification from GeoMaxima Watchdog',
            'timestamp': datetime.utcnow().isoformat()
        }]
        
        success = notifier.send(test_incident)
        
        return {
            'success': success,
            'message': 'Test message sent successfully' if success else 'Failed to send test message'
        }
    except Exception as e:
        return {
            'success': False,
            'message': f'Telegram test failed: {str(e)}'
        }
