'use strict';
'require view';
'require rpc';
'require ui';
'require dom';

/*
 * 面板 LED 控制（PCA9555 所在的那一组）
 *
 * 后端直接读写 /sys/class/leds，所以这里不做任何本地状态缓存：
 * 每次操作后都以 RPC 返回的实际 trigger/brightness 为准。
 *
 * 加这个页面的原因：这块板的面板灯全挂在 I2C 扩展器上，
 * 调 DTS / 驱动时没法从 shell 之外的地方快速确认「哪颗灯对应哪个 GPIO」，
 * 也没法在不重启的情况下试触发器。
 */

var callStatus = rpc.declare({
	object: 'luci.ledctl',
	method: 'status',
	expect: { leds: [] }
});

/*
 * params 必须声明成对象字面量：LuCI 的 declare 只在 params 是数组或对象时
 * 才把调用参数打包成命名对象，缺省时发出去的是空对象 {}，后端什么也收不到。
 */
var callSet = rpc.declare({
	object: 'luci.ledctl',
	method: 'set',
	params: { led: 'str', trigger: 'str', brightness: 'int', delay_on: 'int', delay_off: 'int' }
});

var callAll = rpc.declare({
	object: 'luci.ledctl',
	method: 'all',
	params: { action: 'str' }
});

function notify(kind, msg) {
	ui.addNotification(null, E('p', {}, msg), kind);
}

return view.extend({
	load: function() {
		return callStatus();
	},

	render: function(data) {
		var leds = (data && data.leds) ? data.leds : [];
		var self = this;

		var rows = leds.map(function(l) {
			var sel = E('select', { 'class': 'cbi-input-select' },
				l.triggers.map(function(t) {
					return E('option', {
						'value': t,
						'selected': (t === l.trigger) ? '' : null
					}, t);
				}));

			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, [
					E('strong', {}, l.name),
					l.dev ? E('span', { 'class': 'ifacebadge' }, l.dev) : ''
				]),
				E('td', { 'class': 'td' }, l.trigger || '—'),
				E('td', { 'class': 'td', 'data-led-bright': l.name }, '%d / %d'.format(l.brightness, l.max)),
				E('td', { 'class': 'td' }, sel),
				E('td', { 'class': 'td' }, [
					E('button', {
						'class': 'cbi-button cbi-button-apply',
						'click': ui.createHandlerFn(self, 'handleTrigger', l.name, sel)
					}, _('应用')),
					' ',
					E('button', {
						'class': 'cbi-button cbi-button-action',
						'click': ui.createHandlerFn(self, 'handleBright', l.name, l.max || 1)
					}, _('点亮')),
					' ',
					E('button', {
						'class': 'cbi-button',
						'click': ui.createHandlerFn(self, 'handleBright', l.name, 0)
					}, _('熄灭')),
					' ',
					E('button', {
						'class': 'cbi-button cbi-button-action',
						'click': ui.createHandlerFn(self, 'handleBlink', l.name)
					}, _('1Hz 闪'))
				])
			]);
		});

		var table = E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, _('灯')),
				E('th', { 'class': 'th' }, _('当前触发器')),
				E('th', { 'class': 'th' }, _('亮度')),
				E('th', { 'class': 'th' }, _('触发器')),
				E('th', { 'class': 'th' }, _('操作'))
			])
		].concat(rows));

		var actions = E('div', { 'class': 'cbi-page-actions' }, [
			E('button', {
				'class': 'cbi-button cbi-button-reset',
				'click': ui.createHandlerFn(self, 'handleAll', 'off')
			}, _('全部熄灭')),
			' ',
			E('button', {
				'class': 'cbi-button cbi-button-apply',
				'click': ui.createHandlerFn(self, 'handleAll', 'on')
			}, _('全部点亮')),
			' ',
			E('button', {
				'class': 'cbi-button cbi-button-action',
				'click': ui.createHandlerFn(self, 'handleMarquee')
			}, _('跑马灯')),
			' ',
			E('button', {
				'class': 'cbi-button',
				'click': ui.createHandlerFn(self, 'handleAll', 'restore')
			}, _('恢复默认触发器')),
			' ',
			E('button', {
				'class': 'cbi-button',
				'click': ui.createHandlerFn(self, 'handleRefresh')
			}, _('刷新'))
		]);

		return E('div', {}, [
			E('h2', {}, _('面板 LED 控制')),
			E('div', { 'class': 'cbi-section-descr' },
				_('直接读写 /sys/class/leds。带 i2c 地址标记的灯挂在 PCA9555 扩展器上；' +
				  '「恢复默认触发器」等于 /etc/init.d/led restart。')),
			actions,
			E('div', { 'class': 'cbi-section' }, [ table ])
		]);
	},

	updateBrightness: function(led, value) {
		var cell = document.querySelector('td[data-led-bright="%s"]'.format(led));
		if (cell && value != null)
			cell.textContent = '%d / %d'.format(value, cell.textContent.split('/')[1].trim());
	},

	/*
	 * 注意参数顺序：ui.createHandlerFn(ctx, name, ...args) 生成的处理器是
	 * fn(...args, ev)，额外参数在前、事件对象在最后。这里不需要 ev，直接省略。
	 */
	handleTrigger: function(led, sel) {
		var trigger = sel.value;
		return callSet({ led: led, trigger: trigger }).then(function(res) {
			if (!res || res.ok !== true)
				notify('danger', _('设置失败：%s').format((res && res.error) || _('未知错误')));
			else
				notify('info', _('%s → %s').format(led, trigger));
		});
	},

	handleBright: function(led, value) {
		return callSet({ led: led, brightness: value }).then(function(res) {
			if (!res || res.ok !== true)
				notify('danger', _('设置失败：%s').format((res && res.error) || _('未知错误')));
			else
				this.updateBrightness(led, value);
		}.bind(this));
	},

	handleBlink: function(led) {
		return callSet({ led: led, trigger: 'timer', delay_on: 500, delay_off: 500 }).then(function(res) {
			if (!res || res.ok !== true)
				notify('danger', _('设置失败：%s').format((res && res.error) || _('未知错误')));
			else
				notify('info', _('%s 已切到 1Hz 闪烁').format(led));
		});
	},

	handleAll: function(action) {
		return callAll({ action: action }).then(function(res) {
			if (!res || res.ok !== true) {
				notify('danger', _('操作失败：%s').format((res && res.error) || _('未知错误')));
				return;
			}
			notify('info', action === 'restore'
				? _('已恢复驱动默认触发器')
				: _('已%s全部灯').format(action === 'on' ? _('点亮') : _('熄灭')));
			window.setTimeout(function() { location.reload(); }, 600);
		});
	},

	handleMarquee: function() {
		var self = this;
		var names = Array.prototype.map.call(
			document.querySelectorAll('td[data-led-bright]'),
			function(td) { return td.getAttribute('data-led-bright'); }
		);
		if (!names.length)
			return;

		var i = 0, prev = null;
		var timer = window.setInterval(function() {
			if (prev)
				callSet({ led: prev, trigger: 'none', brightness: 0 });
			if (i >= names.length) {
				window.clearInterval(timer);
				notify('info', _('跑马灯结束'));
				return;
			}
			prev = names[i++];
			callSet({ led: prev, trigger: 'none', brightness: 1 });
		}, 300);

		notify('info', _('跑马灯开始，约 %d 秒，期间别点其他按钮').format(Math.ceil(names.length * 0.3)));
	},

	handleRefresh: function() {
		location.reload();
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
