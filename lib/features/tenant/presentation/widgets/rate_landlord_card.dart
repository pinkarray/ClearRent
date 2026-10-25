import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';

/// Lets a tenant rate their landlord once the tenancy has ended.
///
/// The server (rateLandlord) checks they really were the tenant, that it has
/// ended, and that this tenancy has not been rated before. The comment goes to
/// ClearRent; listings only ever show the average, and only while the admin
/// has that switched on.
class RateLandlordCard extends StatefulWidget {
  final String rentalId;
  const RateLandlordCard({super.key, required this.rentalId});

  @override
  State<RateLandlordCard> createState() => _RateLandlordCardState();
}

class _RateLandlordCardState extends State<RateLandlordCard> {
  bool _loading = true;
  int? _rated;
  int _stars = 0;
  bool _busy = false;
  String? _error;
  final _comment = TextEditingController();

  @override
  void initState() {
    super.initState();
    FirebaseFirestore.instance
        .collection('landlord_reviews')
        .doc(widget.rentalId)
        .get()
        .then((s) {
      if (!mounted) return;
      setState(() {
        _rated = s.exists ? (s.data()?['stars'] as num?)?.toInt() : null;
        _loading = false;
      });
    }).catchError((_) {
      if (mounted) setState(() => _loading = false);
    });
  }

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_stars < 1) {
      setState(() => _error = 'Pick from 1 to 5 stars.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('rateLandlord')
          .call({
        'rentalId': widget.rentalId,
        'stars': _stars,
        'comment': _comment.text.trim(),
      });
      if (mounted) setState(() => _rated = _stars);
    } on FirebaseFunctionsException catch (e) {
      if (mounted) setState(() => _error = e.message ?? 'That did not go through.');
    } catch (_) {
      if (mounted) setState(() => _error = 'That did not go through.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SizedBox.shrink();
    if (_rated != null) {
      return Text('You rated your landlord $_rated ★. Thank you.',
          style: AppTextStyles.bodySmall
              .copyWith(color: AppColors.textSecondary));
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('How was your landlord?', style: AppTextStyles.labelMedium),
          const SizedBox(height: 4),
          Text(
            'Your rating helps the next tenant. Your comment goes to '
            'ClearRent only.',
            style: AppTextStyles.caption
                .copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 8),
          Row(
            children: List.generate(5, (i) {
              final n = i + 1;
              return IconButton(
                tooltip: '$n star${n == 1 ? '' : 's'}',
                onPressed: () => setState(() => _stars = n),
                icon: Icon(
                  n <= _stars ? Icons.star : Icons.star_border,
                  color: n <= _stars ? AppColors.warning : AppColors.textHint,
                ),
              );
            }),
          ),
          TextField(
            controller: _comment,
            maxLength: 500,
            maxLines: 2,
            decoration: const InputDecoration(
              hintText: 'Anything ClearRent should know (optional)',
            ),
          ),
          if (_error != null) ...[
            Text(_error!,
                style: AppTextStyles.caption.copyWith(color: AppColors.error)),
            const SizedBox(height: 6),
          ],
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _busy ? null : _submit,
              child: Text(_busy ? 'Sending…' : 'Submit rating'),
            ),
          ),
        ],
      ),
    );
  }
}
